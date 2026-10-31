#!/bin/bash
# Copies only the public site files into web/dist (never dotfolders like site/.gstack).
set -euo pipefail
cd "$(dirname "$0")"
rm -rf dist && mkdir dist
for f in index.html 404.html _headers robots.txt sitemap.xml llms.txt appcast.xml \
         icon.png mark.png favicon.svg favicon-32.png apple-touch-icon.png og.png \
         show-intro.mp4 show-poster.jpg; do
  cp "../site/$f" dist/
done
cp -R ../site/fonts ../site/art dist/
echo "dist: $(ls dist | wc -l | tr -d ' ') files"
