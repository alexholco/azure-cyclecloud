# azure-cyclecloud
Simple script to deploy and configure cyclecloud in Azure

The script deploys a Cyclecloud server from the Azure Marketplace, creates an initial Cyclecloud admin account and configures the Cyclecloud connection to the Azure subscription. This is meant only for testing purposes and is NOT meant for production.

Prereqs: 
- Install Azure cli
- Install jq
- Log in to Azure via the cli and set the proper subscription

Before running the script, configure the variables at the top of the script

```bash
# configure these variables
location="eastus2"                                                    #Azure region in which to deploy the location 
azure_cloud="public"                                                  #Azure cloud type: china|germany|public|usgov
vm_image="azurecyclecloud:azure-cyclecloud:cyclecloud8:8.2.120211111" #Azure Marketplace image to use ex: "azurecyclecloud:azure-cyclecloud:cyclecloud-79x:7.9.920210614"
allowed_ips="XXX.XXX.XXX.XXX"                                         # * for open access, or your public ip address to limit access via NSG rules for the cyclecloud vm
```

Run the script
```bash
./deploy.sh
```

View information for cyclecloud admin account and ssh connection.
```bash
./deploy.sh -i
```

Delete all azure resources and local temp files
```bash
./deploy.sh -d
```
  
Once complete, you will need to do the following in Cyclecloud:
  - Add ssh key information to the cyclecloud acmin account configuration
  - Set up a scheduler
  
Notes:
  - Files created locally will be stored in /home/<user>/demo-cc
  - Two NSG rules are set up for the cyclecloud vm. Use your public ip address for 'allowed_ips' to limit access.
  - To remove everything (all Azure resources and local files), use the -d parameter or via point and click:
    - Delete the azure resource group: demo-cc-rg
    - Delete the app registration: demo-cc-sp
    - Delete the local temp folder: ~/demo-cc
  - The script has been WOMM certified, but may not work in your environment
