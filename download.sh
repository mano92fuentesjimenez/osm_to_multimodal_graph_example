#!/usr/bin/env bash
set -e
#
CITY="havana"
BBOX="-82.7085,22.9426,-82.0095,23.3278"

wget --progress=dot:mega -O "$CITY.osm" "http://www.overpass-api.de/api/xapi?*[bbox=${BBOX}][@meta]"
