#!/bin/bash
# Список подтверждённых сайтов и их host_id
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

uid=$(wm_user_id)
wm_get "/user/$uid/hosts/" | jq '{
  user_id: '"$uid"',
  hosts: [.hosts[] | {
    host_id,
    url: .unicode_host_url,
    verified,
    main_mirror: (.main_mirror.ascii_host_url // null)
  }]
}'
