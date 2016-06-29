#!/bin/bash

cp -r ../content .

git add .
git commit -m "update"
git push origin master
