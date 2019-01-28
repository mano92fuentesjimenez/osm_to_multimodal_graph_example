# osm_to_multimodal_graph_example
Sequence of steps to build a multimodal graph of transport and examples of route calculations

It will
  1. create a new db using your configs.
  2. Download osm data. 
  3. Build a topologic pedestrian table.
  4. Build a bus table.
  5. Using these table it will build 2 graphs, a multimodal one using pedestrian and bus, and a pedestrian only graph.
  6. Then it will run dijkstra algorithm to show the differences of routing when using the two graphs

