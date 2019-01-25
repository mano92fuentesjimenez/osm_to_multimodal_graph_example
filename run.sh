CITY="Havana"
USER="user"
DB="osm"


BBOX="-82.7085,22.9426,-82.0095,23.3278"
wget --progress=dot:mega -O "$CITY.osm" "http://www.overpass-api.de/api/xapi?*[bbox=${BBOX}][@meta]"


osm2pgrouting -U $USER  -d $DB --schema cars -c /media/mano/Data/projects/projects_data/pgrouting/osm2pgrouting-master/mapconfig_for_cars.xml -f havana.osm
