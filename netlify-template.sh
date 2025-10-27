#!/bin/bash
## change to "bin/sh" when necessary

# Netlify Configuration
auth_token=""                                       # Your Netlify Personal Access Token (get from User Settings > Applications)
dns_zone_id=""                                      # Your DNS Zone ID (found in Domain Settings)
record_name=""                                      # Which record you want to be synced (e.g., "subdomain" or "@" for root)
domain_name=""                                      # Your domain name (e.g., "example.com")
ttl=3600                                            # Set the DNS TTL (seconds)
sitename=""                                         # Title of site "Example Site"
slackchannel=""                                     # Slack Channel #example
slackuri=""                                         # URI for Slack WebHook "https://hooks.slack.com/services/xxxxx"
discorduri=""                                       # URI for Discord WebHook "https://discordapp.com/api/webhooks/xxxxx"


###########################################
## Check if we have a public IP
###########################################
REGEX_IPV4="^(0*(1?[0-9]{1,2}|2([0-4][0-9]|5[0-5]))\.){3}0*(1?[0-9]{1,2}|2([0-4][0-9]|5[0-5]))$"
IP_SERVICES=(
  "https://api.ipify.org"
  "https://ipv4.icanhazip.com"
  "https://ipinfo.io/ip"
)

# Try all the ip services for a valid IPv4 address
for service in ${IP_SERVICES[@]}; do
  RAW_IP=$(curl -s $service)
  if [[ $RAW_IP =~ $REGEX_IPV4 ]]; then
    CURRENT_IP=$BASH_REMATCH
    logger -s "DDNS Updater: Fetched IP $CURRENT_IP"
    break
  else
    logger -s "DDNS Updater: IP service $service failed."
  fi
done

# Exit if IP fetching failed
if [[ -z "$CURRENT_IP" ]]; then
  logger -s "DDNS Updater: Failed to find a valid IP."
  exit 2
fi

###########################################
## Construct the full hostname
###########################################
if [[ "$record_name" == "@" ]]; then
  full_hostname="$domain_name"
else
  full_hostname="$record_name.$domain_name"
fi

###########################################
## Seek for the A record
###########################################

logger "DDNS Updater: Check Initiated"
records=$(curl -s -X GET "https://api.netlify.com/api/v1/dns_zones/$dns_zone_id/dns_records" \
                      -H "Authorization: Bearer $auth_token" \
                      -H "Content-Type: application/json")

###########################################
## Find the specific A record
###########################################
record_id=""
old_ip=""

# Parse the JSON response to find our A record
# Using jq if available, otherwise fallback to sed/grep
if command -v jq &> /dev/null; then
  # Use jq for proper JSON parsing
  record_data=$(echo "$records" | jq -r ".[] | select(.hostname==\"$full_hostname\" and .type==\"A\")")
  if [[ ! -z "$record_data" ]]; then
    record_id=$(echo "$record_data" | jq -r '.id')
    old_ip=$(echo "$record_data" | jq -r '.value')
  fi
else
  # Fallback to grep/sed parsing
  while IFS= read -r line; do
    if [[ $line == *"\"hostname\":\"$full_hostname\""* ]] && [[ $line == *"\"type\":\"A\""* ]]; then
      record_id=$(echo "$line" | sed -E 's/.*"id":"([^"]+)".*/\1/')
      old_ip=$(echo "$line" | sed -E 's/.*"value":"([^"]+)".*/\1/')
      break
    fi
  done <<< "$(echo "$records" | tr '{' '\n')"
fi

###########################################
## Check if the domain has an A record
###########################################
if [[ -z "$record_id" ]]; then
  logger -s "DDNS Updater: A record for $full_hostname does not exist. Creating new record..."
  
  # Create new A record
  create_result=$(curl -s -X POST "https://api.netlify.com/api/v1/dns_zones/$dns_zone_id/dns_records" \
                        -H "Authorization: Bearer $auth_token" \
                        -H "Content-Type: application/json" \
                        --data "{\"type\":\"A\",\"hostname\":\"$full_hostname\",\"value\":\"$CURRENT_IP\",\"ttl\":$ttl}")
  
  if [[ $create_result == *"\"id\""* ]]; then
    logger "DDNS Updater: Successfully created A record for $full_hostname with IP $CURRENT_IP"
    
    if [[ $slackuri != "" ]]; then
      curl -L -X POST $slackuri \
      --data-raw '{
        "channel": "'$slackchannel'",
        "text" : "'"$sitename"' DDNS Record Created: '"$full_hostname"' with IP '"$CURRENT_IP"'"
      }'
    fi
    if [[ $discorduri != "" ]]; then
      curl -i -H "Accept: application/json" -H "Content-Type:application/json" -X POST \
      --data-raw '{
        "content" : "'"$sitename"' DDNS Record Created: '"$full_hostname"' with IP '"$CURRENT_IP"'"
      }' $discorduri
    fi
    exit 0
  else
    logger -s "DDNS Updater: Failed to create A record for $full_hostname"
    exit 1
  fi
fi

###########################################
## Compare if they're the same
###########################################
if [[ $CURRENT_IP == $old_ip ]]; then
  logger "DDNS Updater: IP ($CURRENT_IP) for ${full_hostname} has not changed."
  exit 0
fi

###########################################
## Update the IP using Netlify API
###########################################
# Note: Netlify requires DELETE and CREATE for updates (no PATCH support for DNS records)

# First, delete the old record
delete_result=$(curl -s -X DELETE "https://api.netlify.com/api/v1/dns_zones/$dns_zone_id/dns_records/$record_id" \
                     -H "Authorization: Bearer $auth_token")

# Then create a new record with the updated IP
update_result=$(curl -s -X POST "https://api.netlify.com/api/v1/dns_zones/$dns_zone_id/dns_records" \
                     -H "Authorization: Bearer $auth_token" \
                     -H "Content-Type: application/json" \
                     --data "{\"type\":\"A\",\"hostname\":\"$full_hostname\",\"value\":\"$CURRENT_IP\",\"ttl\":$ttl}")

###########################################
## Report the status
###########################################
if [[ $update_result == *"\"id\""* ]]; then
  logger "DDNS Updater: Successfully updated $full_hostname from $old_ip to $CURRENT_IP"
  
  if [[ $slackuri != "" ]]; then
    curl -L -X POST $slackuri \
    --data-raw '{
      "channel": "'$slackchannel'",
      "text" : "'"$sitename"' Updated: '"$full_hostname"' IP changed from '"$old_ip"' to '"$CURRENT_IP"'"
    }'
  fi
  if [[ $discorduri != "" ]]; then
    curl -i -H "Accept: application/json" -H "Content-Type:application/json" -X POST \
    --data-raw '{
      "content" : "'"$sitename"' Updated: '"$full_hostname"' IP changed from '"$old_ip"' to '"$CURRENT_IP"'"
    }' $discorduri
  fi
  exit 0
else
  echo -e "DDNS Updater: Failed to update $full_hostname to $CURRENT_IP. Response:\n$update_result" | logger -s
  
  if [[ $slackuri != "" ]]; then
    curl -L -X POST $slackuri \
    --data-raw '{
      "channel": "'$slackchannel'",
      "text" : "'"$sitename"' DDNS Update Failed: '"$full_hostname"' could not be updated to '"$CURRENT_IP"'"
    }'
  fi
  if [[ $discorduri != "" ]]; then
    curl -i -H "Accept: application/json" -H "Content-Type:application/json" -X POST \
    --data-raw '{
      "content" : "'"$sitename"' DDNS Update Failed: '"$full_hostname"' could not be updated to '"$CURRENT_IP"'"
    }' $discorduri
  fi
  exit 1
fi
