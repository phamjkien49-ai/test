#!/bin/bash
set -euo pipefail

# =============================
# Enhanced Multi-VM Manager
# =============================

# Function to display header
display_header() {
    clear
    cat << "EOF"
========================================================================
    \_   \__\_       \_\_  \_____\_
   / | / (\_)\__\_ \_/ /\_/\_  \_\_/
  /  |/ / / \_\_ \`/ \_\_ \\/ /   
 / /|  / / /\_/ / / / / /    
/\_/ |\_/\_/\\\_\_, /\_/ /\_/\_/     
        /\___\_/             
                                                                  
                    POWERED BY NighT
========================================================================
EOF
    echo
}

# Function to display colored output
print_status() {
    local type=$1
    local message=$2
    
    case $type in
        "INFO") echo -e "\033[1;34m[INFO]\033[0m $message" ;;
        "WARN") echo -e "\033[1;33m[WARN]\033[0m $message" ;;
        "ERROR") echo -e "\033[1;31m[ERROR]\033[0m $message" ;;
        "SUCCESS") echo -e "\033[1;32m[SUCCESS]\033[0m $message" ;;
        "INPUT") echo -e "\033[1;36m[INPUT]\033[0m $message" ;;
        *) echo "[$type] $message" ;;
    esac
}

# Function to check dependencies
check_dependencies() {
    local deps=("qemu-system-x86_64" "wget" "cloud-localds" "qemu-img")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_status "ERROR" "Missing dependencies: ${missing_deps[*]}"
        print_status "INFO" "On Ubuntu/Debian, try: sudo apt install qemu-system cloud-image-utils wget"
        exit 1
    fi
}

# Function to cleanup temporary files
cleanup() {
    if [ -f "user-data" ]; then rm -f "user-data"; fi
    if [ -f "meta-data" ]; then rm -f "meta-data"; fi
}

# Function to get all VM configurations
get_vm_list() {
    find "$VM_DIR" -name "*.conf" -exec basename {} .conf \; 2>/dev/null | sort
}

# Function to load VM configuration
load_vm_config() {
    local vm_name=$1
    local config_file="$VM_DIR/$vm_name.conf"
    
    if [[ -f "$config_file" ]]; then
        unset VM_NAME OS_TYPE CODENAME IMG_URL HOSTNAME USERNAME PASSWORD
        unset DISK_SIZE MEMORY CPUS SSH_PORT GUI_MODE PORT_FORWARDS IMG_FILE SEED_FILE CREATED
        
        source "$config_file"
        return 0
    else
        print_status "ERROR" "Configuration for VM '$vm_name' not found"
        return 1
    fi
}

# Function to setup VM image (cần thiết cho start_vm)
setup_vm_image() {
    print_status "INFO" "Setting up cloud-init..."

    cat > user-data <<EOF
#cloud-config
hostname: $HOSTNAME
ssh_pwauth: true
disable_root: false
users:
  - name: $USERNAME
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    password: $(openssl passwd -6 "$PASSWORD" | tr -d '\n')
chpasswd:
  list: |
    root:$PASSWORD
    $USERNAME:$PASSWORD
  expire: false
EOF
    cat > meta-data <<EOF
instance-id: iid-$VM_NAME
local-hostname: $HOSTNAME
EOF
    if ! cloud-localds "$SEED_FILE" user-data meta-data; then
        print_status "ERROR" "Failed to create cloud-init seed image"
        exit 1
    fi
}

# Function to start a VM
start_vm() {
    local vm_name=$1
    
    if load_vm_config "$vm_name"; then
        print_status "INFO" "Starting VM: $vm_name"
        print_status "INFO" "SSH: ssh -p $SSH_PORT $USERNAME@localhost"
        print_status "INFO" "Password: $PASSWORD"
        
        if [[ ! -f "$IMG_FILE" ]]; then
            print_status "ERROR" "VM image file not found: $IMG_FILE"
            return 1
        fi
        
        if [[ ! -f "$SEED_FILE" ]]; then
            print_status "WARN" "Seed file not found, recreating..."
            setup_vm_image
        fi
        
        local qemu_cmd=(
            qemu-system-x86_64
            -enable-kvm -m "$MEMORY" -smp "$CPUS" -cpu host
            -drive "file=$IMG_FILE,format=qcow2,if=virtio"
            -drive "file=$SEED_FILE,format=raw,if=virtio"
            -boot order=c
            -device virtio-net-pci,netdev=n0
            -netdev "user,id=n0,hostfwd=tcp::$SSH_PORT-:22"
        )
        if [[ -n "$PORT_FORWARDS" ]]; then
            IFS=',' read -ra forwards <<< "$PORT_FORWARDS"
            for forward in "${forwards[@]}"; do
                IFS=':' read -r host_port guest_port <<< "$forward"
                qemu_cmd+=(-netdev "user,id=n${#qemu_cmd[@]},hostfwd=tcp::$host_port-:$guest_port")
            done
        fi
        if [[ "$GUI_MODE" == true ]]; then
            qemu_cmd+=(-vga virtio -display gtk,gl=on)
        else
            qemu_cmd+=(-nographic -serial mon:stdio)
        fi
        qemu_cmd+=(-device virtio-balloon-pci -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci,rng=rng0)
        
        print_status "INFO" "Starting QEMU..."
        "${qemu_cmd[@]}"
        
        print_status "INFO" "VM $vm_name has been shut down."
    fi
}

# Function to check if VM is running
is_vm_running() {
    local vm_name=$1
    if load_vm_config "$vm_name"; then
        if pgrep -f "qemu-system-x86_64.*$IMG_FILE" >/dev/null; then
            return 0
        else
            return 1
        fi
    fi
    return 1
}

# ====================================================================
# NEW MAIN LOGIC: Bỏ qua menu và chạy trực tiếp
# ====================================================================
run_single_vm() {
    display_header

    local vms=($(get_vm_list))
    local vm_count=${#vms[@]}

    # Kiểm tra nếu có chính xác một máy ảo
    if [ $vm_count -ne 1 ]; then
        print_status "ERROR" "This script requires exactly one VM. Found: $vm_count."
        print_status "INFO" "Please ensure there is only one .conf file in the $VM_DIR directory."
        exit 1
    fi

    local vm_name="${vms[0]}"

    # Kiểm tra nếu máy ảo đã chạy
    if is_vm_running "$vm_name"; then
        print_status "WARN" "VM '$vm_name' is already running."
        exit 0
    fi

    # Bắt đầu chạy máy ảo
    print_status "INFO" "Auto-starting the only available VM: $vm_name"
    start_vm "$vm_name"
}

# --- MAIN EXECUTION ---

trap cleanup EXIT
check_dependencies

VM_DIR="${VM_DIR:-$HOME/vms}"
mkdir -p "$VM_DIR"

# Chạy hàm logic chính
run_single_vm
