#!/bin/sh

animmaker --list $1 --yflip -o$1out.avi
mencoder $1out.avi -ovc rawrgb -o $1out2.avi
#mencoder -of mpeg -ovc lavc -lavcopts vcodec=mpeg1video -oac copy $1out2.avi -o $1out2.mpg


