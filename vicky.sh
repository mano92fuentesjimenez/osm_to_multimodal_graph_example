#!/usr/bin/env bash
#
echo 'This is a simple script to demonstrate how to create a multimodal transport graph '
echo 'We are gonna build one with a level representing pedestrians and another representing busses'
echo 'For pedestrians we are gonna use osm2pgrouting as it creates a topology'
echo 'For busses we are gonna use osm2pgsql because we need a geometry that represents the route of buses '
echo 'Buses level can not be built with osm2pgrouting because it will build a table were there will be a point in all geometries intersections'
echo 'and it is not what we want, remember a traveler cant leave the buss where he want, just on bus stops '
echo 'So we are gonna need a buss stop level too, that is going to be the set of transfer points from pedestrian level to buses level and vice versa '
echo ''

echo usage: vikcy.sh "<postgres parameters>"
echo example: vicky.sh "-p 5432"

CITY="havana"
DB=$CITY

dropdb --if-exists $DB
createdb $DB
psql -d $DB -c 'CREATE EXTENSION postgis' $1
psql -d $DB -c 'CREATE EXTENSION pgrouting' $1
psql -d $DB -c 'CREATE EXTENSION hstore' $1
psql -d $DB -c 'CREATE SCHEMA pedestrian' $1


echo 'Creating level of pedestrian'
osm2pgrouting $1 -d $DB --schema pedestrian --clean -c mapconfig_for_pedestrian.xml -f "$CITY.osm"

exit
echo 'Importing data to create bus level'

osm2pgsql -d $DB -U $USER -E 4326 -H $HOST -k  "$CITY.osm"

echo 'Creating bus level'
psql -h $HOST -U $USER -d $DB -p $PORT -c 'create schema bus'

#For Havana this was the way of getting main busses routes. They are the ones with P1, P2, ... until P16 and PC names.
psql -h $HOST -U $USER -d $DB -p $PORT -c "create table bus.bus_P as select *  from planet_osm_line where route='bus' and ref like 'P%'"

echo 'Creating bus stop level'
#Havent found other way of getting bus stops from P's buses other than getting all bus stop and later intercepting with P's routes.
#There could be a buss stop from one route in other route but that is not a problem for demonstrating multimodal.
psql -h $HOST -U $USER -d $DB -p $PORT -c "create table bus.bus_stops as
                                           select distinct points.* from
                                                          planet_osm_point as points
                                                           inner join
                                                          bus.bus_P as bus
                                                           on (st_intersects(points.way,bus.way))
                                           where points.public_transport='stop_position' and points.tags->'bus' = 'yes';"

echo 'Getting multimodal functions'

git clone https://github.com/mano92fuentesjimenez/pgrouting.git multimodal

cd multimodal
git checkout "usingtables-try2"
psql -h $HOST -U $USER -d $DB -p $PORT -f "./sql/topology/createTopologyMultiModal.sql"

echo 'Creating pedestrian graph'

psql -h $HOST -U $USER -d $DB -p $PORT -c "create schema graphs";
psql -h $HOST -U $USER -d $DB -p $PORT -c "set client_min_messages to 'error'; select  pgr_createtopology_multimodal('{
  \"1\": [
    \"pedestrians\"
  ]
}','{}'
   , '{
  \"pedestrians\": {
    \"sql\": \"select gid as id, the_geom,0 as z_start, 0 as z_end from pedestrian.ways\",
    \"pconn\": 0,
    \"zconn\": 0
  }
}', 'pedestrians', 'graphs', 0.000001);"

echo 'Creating pedestrian and bus graph'

psql -h $HOST -U $USER -d $DB -p $PORT -c "set client_min_messages to 'error'; select  pgr_createtopology_multimodal('{
  \"1\": [
    \"pedestrians\"
  ],
  \"2\": [
    \"buses\"
  ]
}','{\"bus_stops\":[\"pedestrians\",\"buses\"]}'
          , '{
  \"pedestrians\": {
    \"sql\": \"select gid as id, the_geom,0 as z_start, 0 as z_end from pedestrian.ways\",
    \"pconn\": 0,
    \"zconn\": 2
  },\"buses\": {
    \"sql\": \"select osm_id as id, way as the_geom,0 as z_start, 0 as z_end from bus.bus_p\",
    \"pconn\": 0,
    \"zconn\": 2
  },
  \"bus_stops\":{
    \"sql\":\"select osm_id as id, way as the_geom,0 z from bus.bus_stops\",
    \"pconn\":1,
    \"zconn\":2
   }
}', 'bus_and_pedestrians', 'graphs', 0.000001);"

echo 'Adding a cost for every route. Pedestrian will have 5 km/h and busses 50 km/h. Cost will be time spent to arrive.'
echo 'Time spent will be calculated from t = (length(geom)*1)/5 for pedestrians and t =(length(geom)*1)/50 for buses'

psql -h $HOST -U $USER -d $DB -p $PORT -c  "alter table graphs.bus_and_pedestrians add column time_cost float;
                                            alter table graphs.pedestrians add column time_cost float;

                                            update graphs.bus_and_pedestrians set time_cost = ((st_length(geom)*1000)/5)*60 where layname ='pedestrians';
                                            update graphs.pedestrians set time_cost = ((st_length(geom)*1000)/5)*60 where layname ='pedestrians';

                                            update graphs.bus_and_pedestrians set time_cost = ((st_length(geom)*1000)/50)*60 where layname = 'buses'"

echo "creating routes schema"
psql -h $HOST -U $USER -d $DB -p $PORT -c "create schema routes;
                                           create table routes.stops(
                                               geom geometry(point,4326),
                                               id serial primary key
                                           );"

echo "Inserting stops to make dijkstra routes. One route using pedestrian graph and other route using pedestrian and buses graph"


psql -h $HOST -U $USER -d $DB -p $PORT -c "insert into routes.stops (geom) values('SRID=4326;point(-82.38681169999999554 23.14021049999999846)'::geometry);
                                           insert into routes.stops (geom) values('SRID=4326;point(-82.40043959999999856 23.12974420000000109)'::geometry);"

echo "Creating routes tables"
psql -h $HOST -U $USER -d $DB -p $PORT -c  "create table routes.bus_and_pedestrians(
                                              geom geometry(multilinestring),
                                              cost float
                                            );
                                            create table routes.pedestrians(
                                              geom geometry(multilinestring),
                                              cost float
                                            );"
echo "Running dijkstra algorithm on bus and pedestrian graph"
psql -h $HOST -U $USER -d $DB -p $PORT -c  "insert into routes.bus_and_pedestrians
                                            select st_astext(st_collect(graph.geom)), sum(d.cost)
                                            from pgr_dijkstra(' select id, source, target, time_cost as cost, time_cost as reverse_cost from graphs.bus_and_pedestrians',
                                                              (select b.id from graphs.bus_and_pedestrians_pt as b inner join routes.stops as r on ( st_intersects(st_buffer(b.geom,0.000001),r.geom)) where r.id = 1),
                                                              (select b.id from graphs.bus_and_pedestrians_pt as b inner join routes.stops as r on ( st_intersects(st_buffer(b.geom,0.000001),r.geom)) where r.id = 2),
                                                              true
                                                   ) as d inner join graphs.bus_and_pedestrians as graph on(d.edge = graph.id);
                                            "

echo "Running dijkstra algorithm on pedestrian graph"
psql -h $HOST -U $USER -d $DB -p $PORT -c  "insert into routes.pedestrians
                                            select st_astext(st_collect(graph.geom)), sum(d.cost)
                                            from pgr_dijkstra(' select id, source, target, time_cost as cost, time_cost as reverse_cost from graphs.pedestrians',
                                                              (select b.id from graphs.pedestrians_pt as b inner join routes.stops as r on ( st_intersects(st_buffer(b.geom,0.000001),r.geom)) where r.id = 1),
                                                              (select b.id from graphs.pedestrians_pt as b inner join routes.stops as r on ( st_intersects(st_buffer(b.geom,0.000001),r.geom)) where r.id = 2),
                                                              true
                                                   ) as d inner join graphs.pedestrians as graph on(d.edge = graph.id);
                                            "
echo "Adding routes from start point to all bus stops"
psql -h $HOST -U $USER -d $DB -p $PORT -c  "create table routes.nearest_bus_stop as
                                            select *
                                            from _pgr_dijkstraNear(' select id, source, target, time_cost as cost, time_cost as reverse_cost from graphs.bus_and_pedestrians',
                                                              (select b.id from graphs.bus_and_pedestrians_pt as b inner join routes.stops as r on ( st_intersects(st_buffer(b.geom,0.000001),r.geom)) where r.id = 1),
                                                              (select array_agg(id) from graphs.bus_and_pedestrians_pt where  layname = 'bus_stops'),
                                                              10000000,
                                                              true
                                                   ) as d inner join graphs.bus_and_pedestrians as graph on(d.edge = graph.id);"
echo "Finish"
echo "Please see results on qgis. Add the layers in the routes schema, and the ones from the graphs schema  and get your own conclusions"
