#!/bin/bash

#
# Pelican blog auto tool
#

PELICAN_DIR='/home/huntinux/work/pelican/'
BLOG_DIR='/home/huntinux/work/pelican/newblog/'

#
#  enter virtualenv
#
cd $PELICAN_DIR
source ./bin/active

#
# enter blog's root dir
#
cd $BLOG_DIR 
make regenerate &
make serve &

#
# use online Markdown editor
#
firefox http://dillinger.io/  

#
# remeber save file to $BLOG_DIR/content
# output html is in $BLOG_DIR/output
# you can push the 'Update' to you github
#
