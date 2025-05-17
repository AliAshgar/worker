#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() {
    local level=$1
    local message=$2
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    local border="-----------------------------------------------------"
    
    echo -e "${border}"
    case $level in
        "INFO") echo -e "${CYAN}[INFO] ${timestamp} - ${message}${NC}" ;;
        "SUCCESS") echo -e "${GREEN}[SUCCESS] ${timestamp} - ${message}${NC}" ;;
        "ERROR") echo -e "${RED}[ERROR] ${timestamp} - ${message}${NC}" ;;
        *) echo -e "${YELLOW}[UNKNOWN] ${timestamp} - ${message}${NC}" ;;
    esac
    echo -e "${border}\n"
}

check_requirements() {
    for cmd in curl git lsof docker; do
        if ! command -v $cmd &> /dev/null; then
            log "ERROR" "$cmd is not installed. Please install it and rerun the script."
            exit 1
        fi
    done
}

create_network_if_missing() {
    if ! sudo docker network ls | grep -q "brinxai-network"; then
        log "INFO" "Creating Docker network brinxai-network..."
        sudo docker network create brinxai-network
    fi
}

cleanup_containers() {
    local pattern="admier/brinxai_nodes"
    log "INFO" "Searching for containers with pattern: ${pattern}"
    containers=$(docker ps -a --format "{{.ID}} {{.Image}} {{.Names}}" | grep "${pattern}" || true)

    if [ -z "$containers" ]; then
        log "INFO" "No matching containers found. Skipping container cleanup."
    else
        echo "$containers"
        container_ids=$(echo "$containers" | awk '{print $1}')
        docker stop $container_ids && docker rm $container_ids
        log "SUCCESS" "Old containers stopped and removed."
    fi
}

setup_firewall() {
    log "INFO" "Setting up Firewall..."
    sudo apt-get install -y ufw
    sudo ufw allow 22/tcp
    sudo ufw allow 5011/tcp
    sudo ufw --force enable
    sudo ufw status
    log "SUCCESS" "Firewall configured."
}

install_docker() {
    if ! command -v docker &> /dev/null; then
        log "INFO" "Installing Docker..."
        sudo apt-get update
        sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
        echo "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list
        sudo apt-get update
        sudo apt-get install -y docker-ce
    fi
    sudo docker pull admier/brinxai_nodes-worker:latest
}

check_gpu() {
    if lspci | grep -i nvidia > /dev/null; then
        log "INFO" "NVIDIA GPU detected. Installing NVIDIA Container Toolkit..."
        wget https://raw.githubusercontent.com/NVIDIA/nvidia-docker/main/scripts/nvidia-docker-install.sh
        sudo bash nvidia-docker-install.sh
        rm -f nvidia-docker-install.sh
    else
        log "INFO" "No NVIDIA GPU detected. Skipping NVIDIA installation."
    fi
}

check_port() {
    local port=$1
    ! sudo lsof -i -P -n | grep ":$port" > /dev/null
}

find_available_port() {
    local port=$1
    while ! check_port "$port"; do
        port=$((port + 1))
    done
    echo "$port"
}

clone_repository() {
    if [ ! -d "BrinxAI-Worker-Nodes" ]; then
        log "INFO" "Cloning BrinxAI Worker Nodes repository..."
        git clone https://github.com/admier1/BrinxAI-Worker-Nodes
    fi
    cd BrinxAI-Worker-Nodes || exit
    chmod +x install_ubuntu.sh
    ./install_ubuntu.sh
    sudo docker pull admier/brinxai_nodes-worker:latest
    cd ..
}

run_additional_containers() {
    log "INFO" "Starting additional containers..."
    local rembg_port=$(find_available_port 7000)
    local upscaler_port=$(find_available_port 3000)

    for name in rembg upscaler; do
        if docker ps -aq -f name="$name" > /dev/null; then
            log "INFO" "Removing existing container: $name"
            docker rm -f "$name"
        fi
    done

    docker run -d --name rembg --network brinxai-network --cpus=2 --memory=2048m -p 127.0.0.1:"$rembg_port":7000 admier/brinxai_nodes-rembg:latest
    docker run -d --name upscaler --network brinxai-network --cpus=2 --memory=2048m -p 127.0.0.1:"$upscaler_port":3000 admier/brinxai_nodes-upscaler:latest
}

run_brinxai_relay() {
    log "INFO" "Starting BrinxAI Relay..."
    sudo ufw allow 1194/udp
    sudo ufw reload

    if docker ps -q -f name=brinxai_relay; then
        docker rm -f brinxai_relay
    fi

    arch=$(uname -m)
    image="admier/brinxai_nodes-relay:latest"
    [ "$arch" == "aarch64" ] || [ "$arch" == "arm64" ] && image="admier/brinxai_nodes-relay:arm64"

    docker run -d --name brinxai_relay --cap-add=NET_ADMIN -p 1194:1194/udp "$image"
}

main() {
    curl -s https://file.winsnip.xyz/file/uploads/Logo-winsip.sh | bash
    echo "Starting Auto Install Nodes And Relayer for BrinxAI"
    sleep 3
    check_requirements
    create_network_if_missing
    cleanup_containers
    setup_firewall
    install_docker
    check_gpu
    clone_repository
    run_additional_containers
    run_brinxai_relay
    log "SUCCESS" "Installation complete. Access at: https://workers.brinxai.com"
    log "INFO" "To check logs: docker logs brinxai-worker-nodes-worker-1"
}

main
