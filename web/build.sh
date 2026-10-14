#!/bin/bash
# Copies only the public site files into web/dist (never dotfolders like site/.gstack).
set -euo pipefail
cd "$(dirname "$0")"
rm -rf dist && mkdir dist
for f in index.html 404.html _headers robots.txt sitemap.xml llms.txt \
         icon.png favicon-32.png apple-touch-icon.png og.png demo-poster.jpg demo.mp4 region.mp3 dictate.mp3; do
  cp "../site/$f" dist/
done
echo "dist: $(ls dist | wc -l | tr -d ' ') files"
