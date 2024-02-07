#!/bin/sh

# helper-license.sh

# Change the contents of this output to get the environment variables
# of interest. The output must be valid JSON, with strings for both
# keys and values.

userDisplayName=$(dscl . -read "/Users/$($USER | awk '{print $1}')" RealName | sed -n 's/^ //g;2p')


cat <<EOF
{
  "whoami": "$userDisplayName"
}
EOF