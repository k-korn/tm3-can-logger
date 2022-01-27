#!/bin/bash

#parse ouput of can-errors.pl with help of /root/my.dbc DBC file

tail -80  /data/logs/can-errors.log |cantools decode ~/my.dbc |grep -vE ': 0,?$' |grep -v 'expected multiplexer'

