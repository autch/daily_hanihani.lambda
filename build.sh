#!/bin/sh

docker build -t build-daily_hanihani .
docker run --rm -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY build-daily_hanihani

