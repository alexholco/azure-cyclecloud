#!/bin/bash

# jq is required
# files are saved in /<temp_folder>/

# configure these variables
location="southcentralus"
azure_cloud="public"                                                  #china|germany|public|usgov
vm_image="azurecyclecloud:azure-cyclecloud:cyclecloud8:8.2.120211111" #"azurecyclecloud:azure-cyclecloud:cyclecloud-79x:7.9.920210614"
allowed_ips="xxx.xxx.xxx.xxx"                                         # * for open access, or your ip address to limit access

function displayHelp() {
    echo "Usage: deploy.sh [OPTION]"
    echo "deploy.sh           Create azure resources and configure cyclecloud"
    echo "              -c    Configure Cyclecloud with azure subscription information and initial hpc user account"
    echo "              -d    Delete azure resources and local temp files"
    echo "              -h    Display help information"
    echo "              -i    Display ssh instructions and info for hpc admin account"
    echo "              -r    Create azure resources"
}

# vars to drive what will be done
delete_everything=0
configure_cyclecloud=0
create_resources=0
display_ssh_info=0
input_args=$@
if [[ ${#input_args} -eq 0 ]]; then
    configure_cyclecloud=1
    create_resources=1
    display_ssh_info=1
else
    while getopts cdhir flag; do
        case $flag in
        c)
            configure_cyclecloud=1
            ;;
        d)
            delete_everything=1
            ;;
        i)
            display_ssh_info=1
            ;;
        r)
            create_resources=1
            ;;
        h | *)
            displayHelp
            ;;
        esac
    done
fi

# create resource group
# $1 resource group name
# $2 location
function createResourceGroup() {
    echo "Create Resource Group $1 in location $location"
    az group create \
        --name $1 \
        --location $2 \
        --output none
    echo "Created Resource Group $resource_group"
}

# create vnet
# $1 resource group name
# $2 vnet name
# $3 subnet name
function createVNet() {
    echo "Create vNET $2"
    az network vnet create \
        --resource-group $1 \
        --name $2 \
        --subnet-name $3 \
        --output none
    echo "Created vNET $2 in $1"
}

# create a folder if it doesn't already exist
# $1 folder
function ensureFolder() {
    if [ ! -d $1 ]; then
        mkdir $1
        echo "Created folder $1"
    else
        echo "Folder $1 already exists"
    fi
}

# check to see if a file exists
# $1 full path of file
# return code 0/1 (true/false)
function fileExists() {
    if [ -f $1 ]; then
        return 0
    else
        return 1
    fi
}

# get the password from the account data file, or generate a new one
# $1 full path to account data file
# $2 generate if it doesn't exist (true / false)
function getAccountPassword() {
    # try to get password from account data file.
    local pwd=null
    if $(fileExists $1); then
        pwd=$(jq -r ".[3].RawPassword" $1)
    fi
    if [ $pwd = "null" ] && [ $2 = true ]; then
        pwd="pO1*$(generateRandomString)"
    fi
    echo $pwd
}

# create pub/private key
# $1 full path of ssh key
function createSshKey() {
    if $(fileExists $1); then
        echo "SSH key $1 already exists"
    else
        echo "Create ssh key"
        ssh-keygen -m PEM -t rsa -b 4096 -f $1 -N ''
        echo "Created ssh key $1"
    fi
}

# create vm
# $1 resource group name
# $2 vm name
# $3 vm image
# $4 vm user name
# $5 ssh public key file
# $6 public ip resource name
# $7 full path to vm info file
function createVm() {
    if $(fileExists $7); then
        echo "Skipping VM. Info file $7 already exists."
    else
        echo "Create VM $2 using image $3"
        local vm_info=$(az vm create \
            --resource-group $1 \
            --name $2 \
            --image $3 \
            --admin-username $4 \
            --ssh-key-values $5 \
            --public-ip-address $6 \
            --public-ip-sku Standard)
        echo "Created VM $2 in $1"
        echo $vm_info >$7
    fi
}

# create nsg rule
# $1 resource group name
# $2 nsg name
# $3 rule name
# $4 priority
# $5 allowed ip addresses
# $6 destination port ranges
function createNSGRule() {
    echo "Create NSG rule"
    az network nsg rule create \
        --resource-group $1 \
        --nsg-name $2 \
        --name $3 \
        --priority $4 \
        --source-address-prefixes $5 \
        --source-port-ranges '*' \
        --destination-address-prefixes '*' \
        --destination-port-ranges $6 \
        --access Allow \
        --protocol '*' \
        --description "Allow from specific IP address range on port $6" \
        --output none
    echo "Created NSG rule for port $6 and source addresses $5"
}

# create the cluster storage
# $1 resource group name
# $2 location
# $3 storage account info file
function createStorageAccount() {
    if $(fileExists $3); then
        echo "Skipping storage account. Info file $3 already exists."
    else
        local random_string=$(generateRandomString)
        local storage_account_name="${storage_base_name,,}${random_string,,}stg"
        echo "Create Storage Account $storage_account_name in location $2"
        az storage account create \
            --name $storage_account_name \
            --resource-group $1 \
            --location $2 \
            --sku Standard_LRS \
            --kind StorageV2 \
            --output none
        echo "Created Storage Account $storage_account_name in $1"
        echo "{ \"StorageAccountName\": \"$storage_account_name\" }" >$3
    fi
}

# create the app registration
# $1 service principal name
# $2 Service Principal info file
function createAppRegistration() {
    if $(fileExists $2); then
        echo "Skipping App registration. Info file $2 already exists"
    else
        echo "Create Service Principal $1"
        sp_info=$(az ad sp create-for-rbac \
            --name $1 \
            --years 1 \
            --role Contributor)
        echo "Created Service Principal $1"
        echo $sp_info >$2
    fi
}

# create the account_data.json file on cc in /opt/cycle_server/config/data/account_data.json
function generateRandomString() {
    echo "$(date +%s | sha256sum | base64 | head -c 10)"
}

# create account data file
# $1 hpc admin user name
# $2 hpc password
# $3 Account data file
function generateAccountDataFile() {
    echo "Creating file $3"
    local json="
    [
        {
            \"AdType\": \"Application.Setting\",
            \"Name\": \"cycleserver.installation.initial_user\",
            \"Value\": \"$1\"
        },
        {
            \"Category\": \"system\",
            \"Status\": \"internal\",
            \"AdType\": \"Application.Setting\",
            \"Description\": \"CycleCloud distribution method e.g. marketplace, container, manual.\",
            \"Value\": \"manual\",
            \"Name\": \"distribution_method\"
        },
        {
            \"AdType\": \"Application.Setting\",
            \"Name\": \"cycleserver.installation.complete\",
            \"Value\": true
        },
        {
            \"AdType\": \"AuthenticatedUser\",
            \"Name\": \"$1\",
            \"RawPassword\": \"$2\",
            \"Superuser\": true
        }
    ]"
    echo $json >$3
    echo "Created file $3"
}

# generate azure data
# $1 azure cloud (china|germany|public|usgov)
# $2 resource group name
# $3 location
# $4 azure data file
# $5 service principal info file
# $6 storage info file
function generateAzureDataFile() {
    echo "Creating file $4"
    local app_id=$(jq -r '.appId' $5)
    local app_secret=$(jq -r '.password' $5)
    local tenant_id=$(jq -r '.tenant' $5)
    local storage_account_name=$(jq -r '.StorageAccountName' $6)
    local subscription_id=$(az account show | jq -r '.id')
    local json="
    {
        \"Environment\": \"$1\",
        \"AzureResourceGroup\": \"$2\",
        \"AzureRMApplicationId\": \"$app_id\",
        \"AzureRMApplicationSecret\": \"$app_secret\",
        \"AzureRMSubscriptionId\": \"$subscription_id\",
        \"AzureRMTenantId\": \"$tenant_id\",
        \"DefaultAccount\": true,
        \"Location\": \"$3\",
        \"Name\": \"azure\",
        \"Provider\": \"azure\",
        \"ProviderId\": \"$subscription_id\",
        \"RMStorageAccount\": \"$storage_account_name\",
        \"RMStorageContainer\": \"cyclecloud\"
    }"
    echo $json >$4
    echo "Created file $4"
}

# generate script to configure cyclecloud
# $1 hpc admin user name
# $2 hpc password
# $3 temp folder
# $4 upload folder
function generateCyclecloudConfigScript() {
    echo "Creating file $3/cyclecloud_config.sh"
    cat <<EOF >$3/cyclecloud_config.sh
#!/bin/bash

echo "Adding account data file so we can initialize the cli"
sudo mv $4/account_data.json /opt/cycle_server/config/data/account_data.json

echo "Allow account import to complete"
sleep 5

echo "(Re)Starting cycle server"
sudo /opt/cycle_server/cycle_server stop
sudo /opt/cycle_server/cycle_server start
sudo /opt/cycle_server/cycle_server await_startup

echo "Initializing cyclecloud cli"
sudo /usr/local/bin/cyclecloud initialize --loglevel=debug --batch --force --url=https://localhost --verify-ssl=false --username=$1 --password=$2

echo "Creating cyclecloud azure account"
sudo /usr/local/bin/cyclecloud account create -f $4/azure_data.json

EOF
    echo "Created file $3/cyclecloud_config.sh"
}

# set the variables
# resource names
base_name="demo-cc"
storage_base_name="democc"
resource_group="$base_name-rg"
vnet_name="$base_name-vnet"
subnet_name="$base_name-subnet"
vm_name="$base_name-vm"
public_ip="$base_name-pip"
ssh_key_name="$base_name-key"
service_principal_name="$base_name-sp"
nsg_name="${vm_name}NSG"

# account names
vm_user_name="azureuser"
hpc_user_name="hpcadmin"

# folder/file names
temp_folder="$HOME/$base_name"
upload_folder="/home/$vm_user_name/$base_name"
vm_file="$temp_folder/$base_name-vminfo.json"
sp_file="$temp_folder/$base_name-spinfo.json"
stg_file="$temp_folder/$base_name-stginfo.json"
azure_data_file=$temp_folder/azure_data.json
account_data_file=$temp_folder/account_data.json

# ********************************************
# Remove files and resources
# ********************************************
if [ $delete_everything -eq 1 ]; then
    # delete the resources
    echo "Deleting resource group and all resources in $resource_group"
    az group delete --name $resource_group --yes

    # delete the app registration
    if $(fileExists $sp_file); then
        service_principal_id=$(jq -r '.appId' $sp_file)
        echo "Deleting service principal $service_principal_name $service_principal_id"
        az ad sp delete --id $service_principal_id
    else
        echo "Service principal info file does not exist. Skipping delete."
    fi

    # delete the local files
    if [ -d $temp_folder ]; then
        echo "Deleting temporary files and folders in $temp_folder"
        rm -r $temp_folder
    else
        echo "Folder $temp_folder does not exist. Skipping delete."
    fi

    echo "Done removing resources."
fi

# ********************************************
# Create the resources
# ********************************************
if [ $create_resources -eq 1 ]; then
    # create the resource group
    createResourceGroup $resource_group $location

    # create the vnet
    createVNet $resource_group $vnet_name $subnet_name

    # create the temp folder
    ensureFolder $temp_folder

    # create the ssh key
    createSshKey $temp_folder/$ssh_key_name

    # create the vm and save the info
    createVm $resource_group $vm_name $vm_image $vm_user_name $temp_folder/"$ssh_key_name".pub $public_ip $vm_file

    # create nsg rules
    createNSGRule $resource_group $nsg_name Http_80 1010 $allowed_ips 80
    createNSGRule $resource_group $nsg_name Http_443 1020 $allowed_ips 443

    # create the storage account and save the info
    createStorageAccount $resource_group $location $stg_file

    # create the service principal and save the info
    createAppRegistration $service_principal_name $sp_file
fi

# ********************************************
# Configure CycleCloud
# ********************************************
if [ $configure_cyclecloud -eq 1 ]; then

    if $(fileExists $sp_file) && $(fileExists $vm_file) && $(fileExists $stg_file); then
        # set up the values
        vm_ip_address=$(jq -r '.publicIpAddress' $vm_file)
        hpc_password=$(getAccountPassword $account_data_file true)

        echo "hpc_password: $hpc_password"

        # generate the files we need
        echo "Preparing files for cyclecloud configuration"
        generateAzureDataFile $azure_cloud $resource_group $location $azure_data_file $sp_file $stg_file
        generateAccountDataFile $hpc_user_name $hpc_password $account_data_file
        generateCyclecloudConfigScript $hpc_user_name $hpc_password $temp_folder $upload_folder

        # upload files to cyclecloud vm and execute the config script
        echo "Configuring cyclecloud"
        ssh -o StrictHostKeyChecking=no -i $temp_folder/$ssh_key_name $vm_user_name@$vm_ip_address "mkdir -p $upload_folder" &&
            scp -i $temp_folder/$ssh_key_name $temp_folder/cyclecloud_config.sh $temp_folder/account_data.json $temp_folder/azure_data.json $vm_user_name@$vm_ip_address:$upload_folder &&
            ssh -o StrictHostKeyChecking=no -i $temp_folder/$ssh_key_name $vm_user_name@$vm_ip_address "chmod 755 $upload_folder/cyclecloud_config.sh; sudo -s bash $upload_folder/cyclecloud_config.sh"

        echo "***********************************"
        echo "Cyclecloud configurtion complete."
        echo "If there were no errors, you can now"
        echo "create a scheduler and run HPC jobs"
    else
        if ! $(fileExists $sp_file); then
            echo "  Configuration file $sp_file not found"
        fi
        if ! $(fileExists $vm_file); then
            echo "  Configuration file $vm_file not found"
        fi
        if ! $(fileExists $stg_file); then
            echo "  Configuration file $stg_file not found"
        fi
        echo "One or more config files not found. Skipping configuration"
        echo "Rerun deployment to recreate configuration files."
    fi
fi

# ********************************************
# Display the ssh info
# ********************************************
if [ $display_ssh_info -eq 1 ]; then
    if ! $(fileExists $vm_file); then
        echo "Unable to obtain configuration information"
        echo "  File $vm_file not found."
    else
        vm_ip_address=$(jq -r '.publicIpAddress' $vm_file)
        hpc_password=$(getAccountPassword $account_data_file false)
        echo "***********************************"
        echo "Connect to the cyclecloud web site:"
        echo "Cyclecloud url: https://$vm_ip_address"
        echo "User: $hpc_user_name"
        echo "Password: $hpc_password"
        echo ""
        echo "Connect to the cyclecloud vm:"
        echo "ssh -i $temp_folder/$ssh_key_name $vm_user_name@$vm_ip_address"
        echo ""
        echo "To remove everything, run: "
        echo "$ ./deploy.sh -d"
        echo "***********************************"
    fi
fi
