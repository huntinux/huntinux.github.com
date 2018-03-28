#!/bin/bash

#
# Pelican blog auto tool
#

PELICAN_DIR='/home/jinger/virtualenvs/pelican/'
BLOG_DIR='/home/jinger/virtualenvs/pelican/'

#
#  enter virtualenv
#
cd $PELICAN_DIR
source ./bin/activate

#
# enter blog's root dir
#
cd $BLOG_DIR 
make regenerate &
make serve &

#
# use online Markdown editor
#
firefox http://localhost:8000 

#
# remeber save file to $BLOG_DIR/content
# output html is in $BLOG_DIR/output
# you can push the 'Update' to you github
#
