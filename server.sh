#!/bin/bash
# INFO1112 Assignment 2 - server.sh
# Run inside the Alpine container:  bash server.sh
# Needs: apk add bash curl html2text jq netcat-openbsd iproute2 python3 py3-matplotlib

LISTEN_PORT=1234
POI_URL="https://maps.six.nsw.gov.au/arcgis/rest/services/public/NSW_POI/MapServer/0/query"
POI_DISTANCE_M=1000   # "neighbouring" = within this many metres (tutor: fixed in the server, 1000-5000 is fine)
POP_MEASURE="Estimated resident population (no.)"   # selects the row; the numbers come from the CSV
ASSIGN_KEY="Assignment 2"   # selects WHICH assessment row to show; the values come from the page
ASSIGN_URL="https://www.sydney.edu.au/units/INFO1112/2026-S2C-ND-CC"
POP_URL="https://dbr.abs.gov.au/processedData/csv/STE_1.csv"
DIR=$(dirname "$(readlink -f "$0")"). # SCRIPTS OWN PATH 
WORK=$(mktemp -d) # TEMPORARY directory for working files, CSV, PNG 
FIFO="$WORK/fifo"; # named pipe  
ERRLOG="$WORK/nc.err"  #netcat stderr for client ip and port 
mkfifo "$FIFO"
trap 'rm -rf "$WORK"' EXIT #delete temp file

# ---- IP from ifconfig (no hardcoding); handles "inet addr:1.2.3.4" and "inet 1.2.3.4" formats ----
for cmd in ifconfig ss nc curl html2text jq python3; do
  command -v "$cmd" >/dev/null || echo "WARNING: '$cmd' is not installed (see apk add line at top)" >&2
done
SERVER_IP=$(ifconfig 2>/dev/null | sed -n -e 's/.*inet addr:\([0-9.]*\).*/\1/p' -e 's/.*inet \([0-9.]*\) .*/\1/p' | grep -v '^127\.' | head -1)

# Prints the server is running at <IP>, port = {port>
announce() {
  local port="" i
  for i in 1 2 3 4 5; do. # try for 5 times 
    sleep 1
    port=$(ss -ltnp 2>/dev/null | awk '/"nc"/ {n=split($4,a,":"); print a[n]; exit}')
    [ -n "$port" ] && break # found, break 
  done
  echo "The server is running at $SERVER_IP, port=$port"
  [ -n "$SERVER_IP" ] || echo "WARNING: could not find IP - run 'ifconfig' and check its format" >&2
  [ -n "$port" ] || echo "WARNING: could not find port - run 'ss -ltnp' (needs iproute2)" >&2
} 

# Errors go to the server terminal AND the client, stderr
err() { echo "Error: $*" >&2; echo "Error: $*"; }

#Function for assignment request 
do_assignment() {
  local html text block l1 l2 l3 title topic day mony hh mm points due
  html=$(curl -fsS --max-time 15 "$ASSIGN_URL") || { err "could not download the unit page"; return; } # fail on error, silence progress bar, show real error 
  text=$(echo "$html" | html2text) || { err "html2text failed"; return; }   # concert to text 
  [ -n "$text" ] || { err "unit page was empty"; return; }

  # Only the assignment's row: the matching line plus the 2 lines after it
  block=$(echo "$text" | grep -m1 -A2 "$ASSIGN_KEY") #match "assignment 2" & take first 3 lines 
  [ -n "$block" ] || { err "'$ASSIGN_KEY' not found on the unit page"; return; }
  echo "$block" >&2

  # Parse the 3-line table row (all values come from the page)
  l1=$(echo "$block" | sed -n 1p); l2=$(echo "$block" | sed -n 2p); l3=$(echo "$block" | sed -n 3p)
  title=$(echo "$l1"  | grep -oE 'Assignment [0-9]+')
  day=$(echo "$l1"    | sed -n 's/.*Due date: *\([0-9]*\).*/\1/p')
  mony=$(echo "$l2"   | grep -oE '[A-Z][a-z]{2} [0-9]{4}') #month and year 
  hh=$(echo "$l2"     | grep -oE 'at [0-9]{1,2}:' | tr -d 'at :')
  points=$(echo "$l2" | grep -oE '[0-9]+%' | tr -d '%')
  mm=$(echo "$l3"     | grep -oE '[0-9]+ *$' | tr -d ' ')
  topic=$(echo "$l3"  | sed -E 's/[0-9]+ *$//; s/^ *//; s/ *$//')
  due="$day $mony $hh:$mm"

  #if anything is empty print an error 
  if [ -z "$title" ] || [ -z "$day" ] || [ -z "$mony" ] || [ -z "$hh" ] || [ -z "$mm" ] || [ -z "$points" ] || [ -z "$topic" ]; then
    err "could not extract all assignment details from the page"; return
  fi
  printf '{\n  "title" : "%s",\n  "topic" : "%s",\n  "due_date" : "%s",\n  "points" : %s\n}\n' \
    "$title" "$topic" "$due" "$points" | tee "$WORK/assignment.json"
}
#otherwise printf makes json, tee sends to client 


# Function for population requests 
do_population() {
  local csv="$WORK/pop.csv" series="$WORK/series.csv" png="$WORK/population.png" latest
  curl -fsS --max-time 30 -o "$csv" "$POP_URL" || { err "could not download population CSV"; return; } #-o save CSV to temp
  [ -s "$csv" ] || { err "downloaded population CSV is empty"; return; } #test file exist and not empty

  #  one row per measure, one column per year
  # Take the header years and the values on the total-population row; skip blank years.
  #remove invisible /r, then pipe into awk 
  tr -d '\r' < "$csv" | awk -F, -v measure="$POP_MEASURE" ' 
    NR==1 { for (i=4; i<=NF; i++) year[i]=$i; next }
    $3==measure { for (i=4; i<=NF; i++) if ($i != "") print year[i] "," $i; exit }
  ' > "$series"
  [ -s "$series" ] || { err "no row '$POP_MEASURE' found in the population CSV"; return; }
#NR = current line 
#NF = no. of fields 
# turn into date population pairs 
  latest=$(tail -1 "$series") #take the last line 
  echo "Latest NSW population (${latest%%,*}): ${latest#*,}" >&2 #Remove everything past first comma


#Plot using ai generated plot script with mpl 
  echo "Generating plot..." >&2
  [ -f "$DIR/plot.py" ] || { err "plot.py not found in $DIR (copy it into the container)"; return; } #check exist 
  MPLBACKEND=Agg timeout 180 python3 "$DIR/plot.py" "$series" "$png" >&2 \ 
    || { err "plotting failed or timed out (is python3 / matplotlib installed?)"; return; } #run with no screen to file only
  [ -s "$png" ] || { err "population.png was not created"; return; }
  echo "Plot created ($(wc -c < "$png") bytes). Sending population.png to the client..." >&2
  cat "$png" || echo "WARNING: sending failed (exit $?) - the client may have disconnected" >&2.  #send to client via cat 
  echo "Finished sending population.png" >&2 
}



# Query the NSW POI layer; stdout = raw JSON. Extra args are more --data-urlencode pairs.
poi_query() {
  curl -fsS --max-time 25 -G \
    --data-urlencode "outFields=poiname,poitype" \
    --data-urlencode "returnGeometry=true" \
    --data-urlencode "outSR=4283" \
    --data-urlencode "f=json" \
    "$@" "$POI_URL"
}

# Client sends a POI name (any case) or "lat,lon" (GDA94 degrees, latitude first).
do_poi() {
  local raw="$1" name resp x y label count sq
  if echo "$raw" | grep -qE '^-?[0-9]+(\.[0-9]+)? *, *-?[0-9]+(\.[0-9]+)?$'; then
    # coordinates: lat,lon
    y=$(echo "$raw" | cut -d, -f1 | tr -d ' '); x=$(echo "$raw" | cut -d, -f2 | tr -d ' ')
    label="$y,$x"
  else
    # name: the layer stores names in capitals; double any ' for the SQL where-clause
    name=$(echo "$raw" | tr 'a-z' 'A-Z' | sed "s/'/''/g")
    resp=$(poi_query --data-urlencode "where=poiname='$name'") \
      || { err "could not reach the NSW POI service"; return; }
    if echo "$resp" | jq -e '.error' >/dev/null 2>&1; then
      err "POI service error: $(echo "$resp" | jq -r '.error.message')"; return
    fi
    count=$(echo "$resp" | jq '.features | length' 2>/dev/null)
    [ "${count:-0}" -gt 0 ] || { err "POI not found: '$raw'"; return; }
    x=$(echo "$resp" | jq '.features[0].geometry.x'); y=$(echo "$resp" | jq '.features[0].geometry.y')
    label=$(echo "$resp" | jq -r '.features[0].attributes.poiname')
  fi

  # everything within POI_DISTANCE_M metres of that point
  resp=$(poi_query \
    --data-urlencode "where=1=1" \
    --data-urlencode "geometry={\"x\":$x,\"y\":$y,\"spatialReference\":{\"wkid\":4283}}" \
    --data-urlencode "geometryType=esriGeometryPoint" \
    --data-urlencode "inSR=4283" \
    --data-urlencode "spatialRel=esriSpatialRelIntersects" \
    --data-urlencode "distance=$POI_DISTANCE_M" \
    --data-urlencode "units=esriSRUnit_Meter") \
    || { err "could not reach the NSW POI service"; return; }
  if echo "$resp" | jq -e '.error' >/dev/null 2>&1; then
    err "POI service error: $(echo "$resp" | jq -r '.error.message')"; return
  fi

  echo "$resp" | jq --arg poi "$label" --argjson x "$x" --argjson y "$y" --argjson d "$POI_DISTANCE_M" '
    { poi: $poi, centre: {lat: $y, lon: $x}, distance_m: $d,
      neighbours: [ .features[]
        | select(((.geometry.x != $x) or (.geometry.y != $y)) or (.attributes.poiname != $poi))
        | { name: .attributes.poiname, type: .attributes.poitype,
            lat: .geometry.y, lon: .geometry.x } ],
      truncated: (.exceededTransferLimit // false) }' > "$WORK/poi.json" \
    || { err "could not build the neighbours JSON"; return; }

  echo "POI '$label' at lat=$y lon=$x: $(jq '.neighbours | length' "$WORK/poi.json") neighbours within ${POI_DISTANCE_M} m" >&2
  cat "$WORK/poi.json"
}

handle() {
  local raw req
  IFS= read -r raw || return
  raw=$(echo "$raw" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')   # trim (keeps quotes/case)
  req=$(echo "$raw" | tr 'A-Z' 'a-z')
  grep 'Connection received' "$ERRLOG" >&2          # client IP + port
  case "$req" in
    assignment|asssignment) do_assignment ;;         # brief's example has 3 s's
    population)             do_population ;;
    slow)                   sleep 10; echo "done" ;; # for test case (b)
    "")                     err "empty request" ;;
    where\ *)               do_poi "${raw#* }" ;;    # optional "where <poi>" form
    *)                      do_poi "$raw" ;;         # anything else = a POI name or "lat,lon"
  esac
}

# Refuse to start if something (e.g. an old copy of this server) already holds the port
if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${LISTEN_PORT}$"; then
  echo "Error: port $LISTEN_PORT is already in use (an old server.sh or nc may still be running)." >&2
  echo "Find it with:  ss -ltnp | grep $LISTEN_PORT    then stop it with:  kill <pid>" >&2
  exit 1
fi

announce &
while true; do
  : > "$ERRLOG"
  # One connection at a time. While a request is being served nothing is listening,
  # so a second request (even from the same IP) is refused until the first finishes.
  # nc -v logs "Connection received on IP PORT" to stderr; -N closes the socket after our reply.
  nc -lvN "$LISTEN_PORT" < "$FIFO" 2> "$ERRLOG" | handle > "$FIFO"
  # If nc failed straight away (e.g. could not bind), don't spin
  grep -q 'Connection received' "$ERRLOG" || { cat "$ERRLOG" >&2; sleep 2; }
done
