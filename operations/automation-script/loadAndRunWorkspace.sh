#!/bin/bash

# Make sure ATLAS_TOKEN environment variable is set
# to owners team token for organization

# Set PTFE address, organization, and workspace to create. You should edit these before running.
address="roger-ptfe.hashidemos.io"
organization="Solutions-Engineering"
workspace="workspace-from-api"

# You can change sleep duration if desired
sleep_duration=15

# name of person to set name variable to
name=$1

# Override soft-mandatory policy checks that fail
# Set to "yes" or "no"
# if not specified, then we set to "no"
if [ ! -z $2 ]; then
  override=$2
else
  override="no"
fi

# build myconfig.tar.gz
cd config
tar -cvf myconfig.tar .
gzip myconfig.tar
mv myconfig.tar.gz ../.
cd ..

#Set name of workspace in workspace.json
sed "s/placeholder/$workspace/" < workspace.template.json > workspace.json

workspace_result=$(curl --header "Authorization: Bearer $ATLAS_TOKEN" --header "Content-Type: application/vnd.api+json" --request POST --data @workspace.json "https://${address}/api/v2/organizations/${organization}/workspaces")

# Parse workspace_id from workspace_result
workspace_id=$(echo $workspace_result | python3 -c "import sys, json; print(json.load(sys.stdin)['data']['id'])")

echo "Workspace ID: " $workspace_id

# Create configuration versions
configuration_version_result=$(curl --header "Authorization: Bearer $ATLAS_TOKEN" --header "Content-Type: application/vnd.api+json" --data @configversion.json "https://${address}/api/v2/workspaces/${workspace_id}/configuration-versions")

# Parse configuration_version_id and upload_url
config_version_id=$(echo $configuration_version_result | python3 -c "import sys, json; print(json.load(sys.stdin)['data']['id'])")
upload_url=$(echo $configuration_version_result | python3 -c "import sys, json; print(json.load(sys.stdin)['data']['attributes']['upload-url'])")

echo "Config Version ID: " $config_version_id
echo "Upload URL: " $upload_url

# Upload configuration
curl --request PUT -F 'data=@myconfig.tar.gz' "$upload_url"

# Add name variable
sed -e "s/my-name/$name/" -e "s/my-organization/$organization/" -e "s/my-workspace/$workspace/" < variable.template.json  > variable.json

upload_variable_result=$(curl --header "Authorization: Bearer $ATLAS_TOKEN" --header "Content-Type: application/vnd.api+json" --data @variable.json "https://${address}/api/v2/vars?filter%5Borganization%5D%5Busername%5D=${organization}&filter%5Bworkspace%5D%5Bname%5D=${workspace}")

# Do a run
sed "s/workspace_id/$workspace_id/" < run.template.json  > run.json

run_result=$(curl --header "Authorization: Bearer $ATLAS_TOKEN" --header "Content-Type: application/vnd.api+json" --data @run.json https://${address}/api/v2/runs)

# Parse run run_result
run_id=$(echo $run_result | python3 -c "import sys, json; print(json.load(sys.stdin)['data']['id'])")
echo "Run ID: " $run_id

# Check run run result
continue=1
while [ $continue -ne 0 ]; do
  # Sleep a bit
  sleep $sleep_duration
  echo "Checking run status"

  # Check the status
  check_result=$(curl --header "Authorization: Bearer $ATLAS_TOKEN" --header "Content-Type: application/vnd.api+json" https://${address}/api/v2/runs/${run_id})

  # Parse out the startus
  run_status=$(echo $check_result | python3 -c "import sys, json; print(json.load(sys.stdin)['data']['attributes']['status'])")
  echo "Run Status: " $run_status

  # If status is "policy_checked" or "policy_override",
  # then do Apply.  If "errored", exit loop.
  # Anything else, continue loop
  if [[ "$run_status" == "policy_checked" ]] ; then
    continue=0
    # Do the apply
    echo "Policies passed. Doing Apply"
    apply_result=$(curl --header "Authorization: Bearer $ATLAS_TOKEN" --header "Content-Type: application/vnd.api+json" --data @apply.json https://${address}/api/v2/runs/${run_id}/actions/apply)
  elif [[ "$run_status" == "policy_override" ]] && [[ "$override" == "yes" ]]; then
    continue=0
    echo "Some policies failed, but will override"
    # Get the policy check ID
    echo "Getting policy check ID"
    policy_result=$(curl --header "Authorization: Bearer $ATLAS_TOKEN" https://${address}/api/v2/runs/${run_id}/policy-checks)
    # Parse out the policy check ID
    policy_check_id=$(echo $policy_result | python3 -c "import sys, json; print(json.load(sys.stdin)['data'][0]['id'])")
    echo "Policy Check ID: " $policy_check_id
    # Override policy
    echo "Overriding policy check"
    override_result=$(curl --header "Authorization: Bearer $ATLAS_TOKEN" --header "Content-Type: application/vnd.api+json" --request POST https://${address}/api/v2/policy-checks/${policy_check_id}/actions/override)
    # Do the apply
    echo "Doing Apply"
    apply_result=$(curl --header "Authorization: Bearer $ATLAS_TOKEN" --header "Content-Type: application/vnd.api+json" --data @apply.json https://${address}/api/v2/runs/${run_id}/actions/apply)
  elif [[ "$run_status" == "policy_override" ]] && [[ "$override" == "no" ]]; then
    echo "Some policies failed, but will not override. Check run in Terraform Enterprise UI."
    continue=0
  elif [[ "$run_status" == "errored" ]]; then
    echo "Plan errored or hard-mandatory policy failed"
    continue=0
  else
      sleep $sleep_duration
  fi
done
