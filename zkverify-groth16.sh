#!/bin/bash

YELLOW='\033[1;33m'
GREEN='\033[1;32m'
RED='\033[1;31m'
NC='\033[0m'

echo -e "${YELLOW}"
cat << "BANNER"

                              Ang Tanong?                                                                                    
                                                                                                           _.--,-```-.
       ,--.                                                      ,--.                                     /    /      '.  
   ,--/  /|                                ,--,              ,--/  /|   ,---,           ,---,.    ,---,  /  ../         ; 
,---,': / '         ,-.----.             ,--.'|           ,---,': / '  '  .' \        ,'  .'  \  '  .' \ \  ``\  .``-    '
:   : '/ /   ,---.  \    /  \            |  | :           :   : '/ /  /  ;    '.    ,---.' .' | /  ;    '.\ ___\/    \   :
|   '   ,   '   ,'\ |   :    |           :  : '           |   '   ,  :  :       \   |   |  |: |:  :       \     \    :   |
'   |  /   /   /   ||   | .\ :  ,--.--.  |  ' |           '   |  /   :  |   /\   \  :   :  :  /:  |   /\   \    |    ;  . 
|   ;  ;  .   ; ,. :.   : |: | /       \ '  | |           |   ;  ;   |  :  ' ;.   : :   |    ; |  :  ' ;.   :  ;   ;   :  
:   '   \ '   | |: :|   |  \ :.--.  .-. ||  | :           :   '   \  |  |  ;/  \   \|   :     \|  |  ;/  \   \/   :   :   
|   |    ''   | .; :|   : .  | \__\/: . .'  : |__         |   |    ' '  :  | \  \ ,'|   |   . |'  :  | \  \ ,'`---'.  |   
'   : |.  \   :    |:     |`-' ," .--.; ||  | '.'|        '   : |.  \|  |  '  '--'  '   :  '; ||  |  '  '--'   `--..`;    
|   | '_\.'\   \  / :   : :   /  /  ,.  |;  :    ;        |   | '_\.'|  :  :        |   |  | ; |  :  :       .--,_        
'   : |     `----'  |   | :  ;  :   .'   \  ,   /         '   : |    |  | ,'        |   :   /  |  | ,'       |    |`.     
;   |,'             `---'.|  |  ,     .-./---`-'          ;   |,'    `--''          |   | ,'   `--''         `-- -`, ;    
'---'                 `---`   `--`---'                    '---'                     `----'                     '---`      

                                                                                              By: _Jheff

        Automated Circom + SnarkJS + zkVerify Groth16 Proof Generator ✨

BANNER
echo -e "${NC}"

# === Install dependencies ===
echo -e "${GREEN}Installing Rust, Circom v2.1.5 and SnarkJS...${NC}"
sudo apt update -y && sudo apt install -y build-essential git curl
curl https://sh.rustup.rs -sSf | sh -s -- -y
source $HOME/.cargo/env

npm install -g snarkjs
rm -rf ~/circom
git clone https://github.com/iden3/circom.git ~/circom
cd ~/circom && git checkout tags/v2.1.5 && cargo build --release
sudo cp target/release/circom /usr/local/bin/
cd ~ || exit

# === Setup project folders ===
mkdir -p ~/zkverify-relayer/{real-proof,data}
cd ~/zkverify-relayer/real-proof || exit

# === Create sum.circom ===
cat > sum.circom <<EOF
pragma circom 2.0.0;

template SumCircuit() {
    signal input a;
    signal input b;
    signal output c;
    c <== a + b;
}

component main = SumCircuit();
EOF

# === Compile ===
echo -e "${GREEN}Compiling circuit with Circom...${NC}"
circom sum.circom --r1cs --wasm --sym -o .

# === Get ptau ===
cd ~/zkverify-relayer
wget -O pot12_final.ptau https://storage.googleapis.com/zkevm/ptau/powersOfTau28_hez_final_10.ptau

# === Setup zkey ===
echo -e "${GREEN}Setting up zkey...${NC}"
snarkjs groth16 setup real-proof/sum.r1cs pot12_final.ptau real-proof/sum.zkey
snarkjs zkey export verificationkey real-proof/sum.zkey real-proof/verification_key.json

# === Input ===
cat > real-proof/input.json <<EOF
{
  "a": "3",
  "b": "11"
}
EOF

# === Generate witness and proof ===
echo -e "${GREEN}Generating witness and proof...${NC}"
snarkjs wtns calculate real-proof/sum_js/sum.wasm real-proof/input.json real-proof/witness.wtns
snarkjs groth16 prove real-proof/sum.zkey real-proof/witness.wtns real-proof/proof.json real-proof/public.json

# === Move to data ===
cp real-proof/{proof.json,public.json,verification_key.json} data/

# === .env setup ===
cd ~/zkverify-relayer
echo -e "${YELLOW}Enter your zkVerify API Key:${NC}"
read -rp "API_KEY: " apikey
echo "API_KEY=$apikey" > .env

# === index.js ===
cat > index.js << 'EOF'
import axios from "axios";
import fs from "fs";
import dotenv from "dotenv";
dotenv.config();

const API_URL = "https://relayer-api.horizenlabs.io/api/v1";
const proof = JSON.parse(fs.readFileSync("./data/proof.json"));
const publicSignals = JSON.parse(fs.readFileSync("./data/public.json"));
const key = JSON.parse(fs.readFileSync("./data/verification_key.json"));

async function main() {
  const params = {
    proofType: "groth16",
    vkRegistered: false,
    proofOptions: {
      library: "snarkjs",
      curve: "bn128"
    },
    proofData: {
      proof,
      publicSignals,
      vk: key
    }
  };

  const res = await axios.post(`${API_URL}/submit-proof/${process.env.API_KEY}`, params);
  console.log("✅ Submitted:", res.data);

  if (res.data.optimisticVerify !== "success") {
    console.error("❌ Optimistic verification failed.");
    return;
  }

  while (true) {
    const job = await axios.get(`${API_URL}/job-status/${process.env.API_KEY}/${res.data.jobId}`);
    console.log("🔁 Status:", job.data.status);
    if (job.data.status === "Finalized") {
      console.log("✅ Finalized:", job.data);
      break;
    }
    await new Promise(r => setTimeout(r, 5000));
  }
}

main();
EOF

# === Node setup ===
npm init -y
npm pkg set type=module
npm install axios dotenv

# === Submit proof ===
echo -e "${GREEN}Submitting to zkVerify Relayer...${NC}"
node index.js
