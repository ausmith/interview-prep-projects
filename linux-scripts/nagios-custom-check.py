#!/usr/bin/env python3

import requests
import sys

failurecounter = 0
# Using a known file path where we will toss this serverlist.txt file
# File contents will be line separated IP addresses of servers to check with HTTP GET requests
filepath = '/usr/local/nagios/etc/serverlist.txt'
f = open(filepath, 'r')
for server in f:
    server = server.strip()
    if server != '':
        # Need to wrap this in a try..except to handle full down scenarios of the endpoints being checked
        try:
            req = requests.get(f"http://{server}", timeout=1)
        except:
            # There was some kind of failure like a timeout, so count as a failure and go to next server
            failurecounter += 1
            continue
        if req.status_code != 200:
            failurecounter += 1
f.close

# Nagios checks have 3 exit codes we care about: 0 == ok; 1 == warn; 2 == critical
# As such, we will exit with 0 if no failures, 1 if a single failure, and 2 if greater than 1 failure or we get a surprise result
print(f"Failure count: {failurecounter}")
if failurecounter == 0:
    sys.exit(0)
elif failurecounter == 1:
    sys.exit(1)
else:
    sys.exit(2)
