#!/bin/sh
/usr/local/bin/pressure-relay &
exec /usr/local/bin/salix-runtime-agent --runtime-agent
