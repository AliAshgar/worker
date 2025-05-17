#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

curl -s https://file.winsnip.xyz/file/uploads/Logo-winsip.sh | bash
echo "Starting Auto Install Nodes And Relayer for BrinxAI"
sleep 5

log() {
    local level=$1
    local message=$2
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    local border="-----------------------------------------------------"

    echo -e "${border}"
    case $level in
        "INFO")
            echo -e "${CYAN}[INFO] ${timestamp} - ${message}${NC}"
            ;;
        "SUCCESS")
            echo -e "${GREEN}[SUCCESS] ${timestamp} - ${message}${NC}"
            ;;
        "ERROR")
            echo -e "${RED}[ERROR] ${timestamp} - ${message}${NC}"
            ;;
        *)
            echo -e "${YELLOW}[UNKNOWN] ${timestamp} - ${message}${NC}"
            ;;
    esac
    echo -e "${border}\n"
}

common() {
    local duration=$1
    local message=$2
    local end=$((SECONDS + duration))
    local spinner="⣷⣯⣟⡿⣿⡿⣟⣯⣷"

    echo -n -e "${YELLOW}${message}...${NC} "
    while [ $SECONDS -lt $end ]; do
        printf "\b${spinner:((SECONDS % ${#spinner}))%${#spinner}:1}"
        sleep 0.1
    done
    printf "\r${GREEN}Done!${NC} \n"
}

cleanup_containers() {
    local pattern="admier/brinxai_nodes"
    log "INFO" "Searching for containers with pattern: ${pattern}"
    containers=$(docker ps --format "{{.ID}} {{.Image}} {{.Names}}" | grep "${pattern}" || true)

    if [ -z "$containers" ]; then
        log "INFO" "No matching containers found. Skipping container cleanup."
        return
    else
        log "INFO" "Containers found:"
        echo "$containers"
        container_ids=$(echo "$containers" | awk '{print $1}')
        log "INFO" "Stopping and removing containers: $container_ids"
        docker stop $container_ids && docker rm $container_ids
    fi
}

setup_firewall() {
    log "INFO" "Setting up Firewall..."
    sudo apt-get update
    sudo apt-get install -y ufw
    sudo ufw allow 22/tcp
    sudo ufw allow 5011/tcp
    sudo ufw allow 1194/udp
    sudo ufw --force enable
    sudo ufw status
}

install_docker() {
    if ! command -v docker &> /dev/null; then
        log "INFO" "Installing Docker and pulling BrinxAI images..."
        sudo apt-get update
        sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
        sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
        sudo apt-get update
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io
        sudo docker pull admier/brinxai_nodes-worker:latest
    else
        log "INFO" "Docker is already installed. Skipping Docker installation."
    fi

    # Optional: add current user to docker group for easier docker usage
    if ! groups $USER | grep -q '\bdocker\b'; then
        log "INFO" "Adding user $USER to docker group"
        sudo usermod -aG docker $USER
        log "INFO" "You may need to logout and login again to apply docker group changes."
    fi
}

check_gpu() {
    if lspci | grep -i nvidia > /dev/null; then
        log "INFO" "NVIDIA GPU detected. Installing NVIDIA Container Toolkit..."
        wget https://raw.githubusercontent.com/NVIDIA/nvidia-docker/main/scripts/nvidia-docker-install.sh -O nvidia-docker-install.sh
        sudo bash nvidia-docker-install.sh
        rm -f nvidia-docker-install.sh
    else
        log "INFO" "No NVIDIA GPU detected. Skipping NVIDIA installation."
    fi
}

check_port() {
    local port=$1
    if sudo lsof -i -P -n | grep ":$port" > /dev/null; then
        return 1
    else
        return 0
    fi
}

find_available_port() {
    local port=$1
    while ! check_port "$port"; do
        port=$((port+1))
    done
    echo "$port"
}

clone_repository() {
    if [ ! -d "BrinxAI-Worker-Nodes" ]; then
        log "INFO" "Cloning BrinxAI Worker Nodes repository..."
        git clone https://github.com/admier1/BrinxAI-Worker-Nodes
    else
        log "INFO" "BrinxAI Worker Nodes repository is already cloned."
    fi

    cd BrinxAI-Worker-Nodes || { log "ERROR" "Failed to enter BrinxAI-Worker-Nodes directory"; exit 1; }
    log "INFO" "Running installation script..."
    chmod +x install_ubuntu.sh
    ./install_ubuntu.sh
    log "INFO" "Pulling the latest Docker image for BrinxAI Worker..."
    sudo docker pull admier/brinxai_nodes-worker:latest
}

run_additional_containers() {
    log "INFO" "Running additional Docker containers..."

    local text_ui_port
    local stable_diffusion_port
    local rembg_port
    local upscaler_port

    text_ui_port=$(find_available_port 5000)
    stable_diffusion_port=$(find_available_port 5050)
    rembg_port=$(find_available_port 7000)
    upscaler_port=$(find_available_port 3000)

    cleanup_container() {
        local container_name=$1
        if sudo docker ps -q -f name="$container_name" | grep -q .; then
            log "INFO" "Stopping and removing container $container_name..."
            sudo docker stop "$container_name" && sudo docker rm "$container_name"
        elif sudo docker ps -aq -f name="$container_name" | grep -q .; then
            log "INFO" "Removing stopped container $container_name..."
            sudo docker rm "$container_name"
        fi
    }

    cleanup_container "text-ui"
    cleanup_container "rembg"
    cleanup_container "upscaler"

    log "INFO" "Running new containers..."

    # Uncomment if you want to run text-ui container, remember to set correct network or ports
    # sudo docker run -d --name text-ui --network brinxai-network --cpus=4 --memory=4096m -p 127.0.0.1:"$text_ui_port":5000 admier/brinxai_nodes-text-ui:latest
    sudo docker run -d --name rembg --network brinxai-network --cpus=2 --memory=2048m -p 127.0.0.1:"$rembg_port":7000 admier/brinxai_nodes-rembg:latest
    sudo docker run -d --name upscaler --network brinxai-network --cpus=2 --memory=2048m -p 127.0.0.1:"$upscaler_port":3000 admier/brinxai_nodes-upscaler:latest
}

run_brinxai_relay() {
    log "INFO" "Running BrinxAI Relay..."

    if command -v ufw &> /dev/null; then
        sudo ufw allow 1194/udp
        sudo ufw reload
    fi

    if command -v firewall-cmd &> /dev/null; then
        sudo firewall-cmd --permanent --add-port=1194/udp
        sudo firewall-cmd --reload
    fi

    if sudo docker ps -q -f name=brinxai_relay | grep -q .; then
        log "INFO" "Stopping existing brinxai_relay container..."
        sudo docker stop brinxai_relay
        sudo docker rm brinxai_relay
    fi

    arch=$(uname -m)
    if [ "$arch" == "x86_64" ]; then
        sudo docker run -d --name brinxai_relay --cap-add=NET_ADMIN -p 1194:1194/udp admier/brinxai_nodes-relay:latest
    elif [ "$arch" == "aarch64" ] || [ "$arch" == "arm64" ]; then
        sudo docker run -d --name brinxai_relay --cap-add=NET_ADMIN -p 1194:1194/udp admier/brinxai_nodes-relay:arm64
    else
        log "ERROR" "Unsupported architecture: $arch"
        exit 1
    fi
}

main() {
    cleanup_containers || log "ERROR" "Container cleanup failed. Proceeding to next step."
    setup_firewall
    install_docker
    check_gpu
    clone_repository
    run_additional_containers
    run_brinxai_relay
    log "INFO" "Input node IP for login: https://workers.brinxai.com"
    log "INFO" "Check logs: docker logs brinxai-worker-nodes-worker-1"
}

main
