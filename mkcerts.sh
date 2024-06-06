#!/usr/bin/env bash

# Load environment variables
export "$(grep -v '^#' .env | xargs)"

# Define colors for output
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
CYAN="\033[1;36m"
RESET="\033[0m"

# Define directory structure
WORKING_DIR=$(dirname "$(realpath "$0")")
ROOT_CA_DIR="$WORKING_DIR/root/ca"
INTERMEDIATE_CA_DIR="$ROOT_CA_DIR/intermediate"
ROOT_CONF="$WORKING_DIR/.root_openssl.cnf"
INTER_CONF="$WORKING_DIR/.intermediate_openssl.cnf"

# Export the working directory so it's available to openssl as an environment variable
export WORKING_DIR

# Create the necessary directory structure for the Root CA
mkdir -p $ROOT_CA_DIR/{certs,crl,newcerts,private}
chmod 700 $ROOT_CA_DIR/private
touch $ROOT_CA_DIR/index.txt
echo 1000 > $ROOT_CA_DIR/serial

# Create the necessary directory structure for the Intermediate CA
mkdir -p $INTERMEDIATE_CA_DIR/{certs,crl,csr,newcerts,private}
chmod 700 $INTERMEDIATE_CA_DIR/private
touch $INTERMEDIATE_CA_DIR/index.txt
echo 1000 > $INTERMEDIATE_CA_DIR/serial
echo 1000 > $INTERMEDIATE_CA_DIR/crlnumber

# Check if openssl is installed
[ ! -x /usr/bin/openssl ] && echo -e "${RED}Openssl not found.${RESET}" && exit 1

# Generate ROOT-CA key and certificate
echo -e "${CYAN}Generating ROOT CA key${RESET}"
openssl genrsa -aes256 -out $ROOT_CA_DIR/private/ca.key.pem 4096

echo -e "\n${YELLOW}Please add the ROOT CA information${RESET}"
openssl req -config "$ROOT_CONF" \
    -key $ROOT_CA_DIR/private/ca.key.pem \
    -new -x509 -days 14600 -sha256 -extensions v3_ca \
    -out $ROOT_CA_DIR/certs/ca.cert.pem

# Generate Subordinate CA key and CSR
echo -e "${CYAN}Generating Intermediate CA key${RESET}"
openssl genrsa -out $INTERMEDIATE_CA_DIR/private/intermediate.key.pem 4096

echo -e "\n${YELLOW}Please add the Intermediate CA information${RESET}"
openssl req -config "$INTER_CONF" -new -sha256 \
    -key $INTERMEDIATE_CA_DIR/private/intermediate.key.pem \
    -out $INTERMEDIATE_CA_DIR/csr/intermediate.csr.pem

# Sign the Subordinate CA with the ROOT CA
echo -e "${CYAN}Signing Intermediate CA with ROOT${RESET}"
openssl ca -config "$ROOT_CONF" -extensions v3_intermediate_ca \
    -days 1825 -notext -md sha256 \
    -in $INTERMEDIATE_CA_DIR/csr/intermediate.csr.pem \
    -out $INTERMEDIATE_CA_DIR/certs/intermediate.cert.pem

# Combine Subordinate Root CA and Intermediate CA into a single PEM file
combined_ca_pem="$INTERMEDIATE_CA_DIR/certs/ca-chain.cert.pem"
cat $INTERMEDIATE_CA_DIR/certs/intermediate.cert.pem \
    $ROOT_CA_DIR/certs/ca.cert.pem > $combined_ca_pem

# Generate WLC key and CSR
echo -e "${CYAN}Generating WLC key${RESET}"
openssl genrsa -aes256 -out $INTERMEDIATE_CA_DIR/private/wlc.key.pem 4096

echo -e "\n${YELLOW}Please add the WLC information${RESET}"
openssl req -new -sha256 \
    -key $INTERMEDIATE_CA_DIR/private/wlc.key.pem \
    -out $INTERMEDIATE_CA_DIR/csr/wlc.csr.pem \
    -passout pass:${PASS} \
    -config $WORKING_DIR/.device.cnf \
    -passin pass:${PASS}

# Sign the WLC CSR with the Intermediate CA
echo -e "${CYAN}Signing WLC CSR with Subordinate CA${RESET}"
openssl ca -config "$INTER_CONF" \
    -extensions usr_cert -days 375 -notext -md sha256 \
    -in "$INTERMEDIATE_CA_DIR/csr/wlc.csr.pem" \
    -out "$INTERMEDIATE_CA_DIR/certs/wlc.cert.pem" \
    -keyfile "$INTERMEDIATE_CA_DIR/private/intermediate.key.pem"

# Check if the WLC certificate was created successfully
if [ -f "$INTERMEDIATE_CA_DIR/certs/wlc.cert.pem" ]; then
    echo -e "${GREEN}WLC certificate signed successfully.${RESET}"
else
    echo -e "${RED}Failed to sign WLC certificate. Please check the configuration and input files.${RESET}"
    exit 1
fi

# Create a PFX bundle
echo -e "${CYAN}Creating PFX bundle for WLC${RESET}"
openssl pkcs12 -export -out "$WORKING_DIR/WLC-CA.pfx" \
    -inkey "$INTERMEDIATE_CA_DIR/private/wlc.key.pem" \
    -in "$INTERMEDIATE_CA_DIR/certs/wlc.cert.pem" \
    -certfile "$combined_ca_pem" \
    -passout pass:${PASS}

# Copy the ca-chain.cert.pem to the working directory
cp "$combined_ca_pem" "$WORKING_DIR/ca-chain.cert.pem"

# Validate the PFX bundle
echo -e "${CYAN}Validating PFX bundle${RESET}"
openssl pkcs12 -in "$WORKING_DIR/WLC-CA.pfx" \
    -noout -info -passin pass:${PASS}

echo -e "${GREEN}Certificate creation and PFX bundling complete!${RESET}"