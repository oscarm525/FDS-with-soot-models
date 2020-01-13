# FDS-with-soot-models
Fork of FDS 6.1 with the posibility to use soot models

To use the soot models add the parameter CAMBIO=.TRUE. to the MISC line at the .fds script.

To use the adjustment of the temperature and mass fraction limits add the parameters CT,CF,COX with the correspondent value to the MISC line at the .fds script.

Example of the misc line:
&MISC CAMBIO=.TRUE.,REAC_SOURCE_CHECK=.TRUE.,CT=0.056,CF=0.003,COX=0.18/
