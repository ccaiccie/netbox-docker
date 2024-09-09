PROJECT_ID=$(gcloud config get-value project)
ZONE=$(gcloud config get-value compute/zone)
UBUNTU_IMAGE=$(gcloud compute images list --project=ubuntu-os-cloud --filter="name~'ubuntu-2204-jammy' AND architecture='X86_64'" --sort-by="~creationTimestamp" --limit=1 --format="value(name)")
gcloud compute instances create netboxvm \
 --machine-type=n2-standard-4 \
 --network-interface=network-tier=PREMIUM,stack-type=IPV4_ONLY,subnet=default \
 --provisioning-model=STANDARD \
 --scopes=https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write,https://www.googleapis.com/auth/servicecontrol,https://www.googleapis.com/auth/service.management.readonly,https://www.googleapis.com/auth/trace.append \
 --create-disk=auto-delete=yes,boot=yes,device-name=gns3,image=projects/ubuntu-os-cloud/global/images/$UBUNTU_IMAGE,mode=rw,size=20,type=projects/$PROJECT_ID/zones/$ZONE/diskTypes/pd-balanced \
 --no-shielded-secure-boot --shielded-vtpm \
 --tags netboxvm \
 --zone $ZONE \
 --enable-nested-virtualization \
 --provisioning-model=SPOT \
 --instance-termination-action=stop \
 --can-ip-forward \
 --metadata serial-port-enable=TRUE,startup-script='#!/bin/bash

# Redirect stdout and stderr to the log file
exec > /var/log/startup-script.log 2>&1

if [ ! -f /opt/netbox/startup-script-ran ]; then
    mkdir -p /opt/netbox
    export DEBIAN_FRONTEND="noninteractive"
    echo "debconf debconf/frontend select Noninteractive" | debconf-set-selections
    echo "APT::Get::Assume-Yes \"true\";" > /tmp/_tmp_apt.conf
    export APT_CONFIG=/tmp/_tmp_apt.conf
    sudo apt-get update
    sudo apt-get install -y ca-certificates curl gnupg
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu jammy stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt update
    sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin expect -y
    git clone -b release https://github.com/netbox-community/netbox-docker.git

    # Setup NetBox and NGINX
    cd netbox-docker
    tee docker-compose-nginx.yml <<EOF1
services:
  nginx:
    image: nginx:latest
    ports:
      - "443:443"
    volumes:
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - ./nginx/certs:/etc/nginx/certs:ro
    networks:
      - netbox-docker_default
    restart: always
networks:
  netbox-docker_default:
    external: true
EOF1

    # NGINX self-signed certificate setup
    mkdir -p ./nginx/certs ./nginx/conf.d
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout ./nginx/certs/selfsigned.key -out ./nginx/certs/selfsigned.crt -subj "/CN=localhost"

    # NGINX configuration
    tee ./nginx/conf.d/default.conf <<EOF
server {
    listen 443 ssl;
    server_name localhost;

    ssl_certificate /etc/nginx/certs/selfsigned.crt;
    ssl_certificate_key /etc/nginx/certs/selfsigned.key;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers "HIGH:!aNULL:!MD5";

    location / {
        proxy_pass http://netbox:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

    # Pull and start the services
    docker compose pull
    docker compose up -d
    touch /opt/netbox/startup-script-ran
    # wait for localhost to respond on port 8080 then run the expect script
while docker ps --filter \"name=netbox-docker-netbox-1\" --format \"{{.Status}}\" | grep -q "starting"; do
        echo "waiting for netbox to start"
        sleep 5
    done
    # Create superuser for NetBox
    expect -c "
    spawn docker exec -it netbox-docker-netbox-1 /opt/netbox/netbox/manage.py createsuperuser
    expect \"Username:\"
    send \"admin\r\"
    expect \"Email address:\"
    send \"admin@netbox.com\r\"
    expect \"Password:\"
    send \"Your_password_here1\r\"
    expect \"Password (again):\"
    send \"Your_password_here1\r\"
    expect eof
    "
fi
if [[ "$(pwd)" == */netbox-docker* ]]; then
    docker compose -f docker-compose-nginx.yml up -d
else
    cd /netbox-docker
    docker compose up -d
    docker compose -f docker-compose-nginx.yml up -d
fi
'
