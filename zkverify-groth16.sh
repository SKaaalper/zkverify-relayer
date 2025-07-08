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

        Automated Circom + SnarkJS + zkVerify Groth16 Proof Generator!

BANNER
echo -e "${NC}"

# === INSTALL DEPENDENCIES ===
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

# === CREATE PROJECT FOLDERS ===
mkdir -p ~/zkverify-relayer/{real-proof,data}
cd ~/zkverify-relayer/real-proof || exit

# === CREATE CIRCUIT ===
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

# === COMPILE CIRCUIT ===
echo -e "${GREEN}Compiling circuit with Circom...${NC}"
circom sum.circom --r1cs --wasm --sym -o .

# === DOWNLOAD PTAU FILE ===
cd ~/zkverify-relayer
wget -O pot12_final.ptau https://storage.googleapis.com/zkevm/ptau/powersOfTau28_hez_final_10.ptau

# === SETUP ZKEY ===
echo -e "${GREEN}Setting up zkey...${NC}"
snarkjs groth16 setup real-proof/sum.r1cs pot12_final.ptau real-proof/sum.zkey
snarkjs zkey export verificationkey real-proof/sum.zkey real-proof/verification_key.json

# === INPUT ===
cat > real-proof/input.json <<EOF
{
  "a": "3",
  "b": "11"
}
EOF

# === GENERATE WITNESS AND PROOF ===
echo -e "${GREEN}Generating witness and proof...${NC}"
snarkjs wtns calculate real-proof/sum_js/sum.wasm real-proof/input.json real-proof/witness.wtns
snarkjs groth16 prove real-proof/sum.zkey real-proof/witness.wtns real-proof/proof.json real-proof/public.json
cp real-proof/{proof.json,public.json,verification_key.json} data/

# === SETUP .env ===
cd ~/zkverify-relayer
echo -e "${YELLOW}Enter your zkVerify API Key:${NC}"
read -rp "API_KEY: " apikey
echo "API_KEY=$apikey" > .env

# === CREATE index.js ===
cat > index.js << 'EOF'
import axios from "axios";
import fs from "fs";
import dotenv from "dotenv";
dotenv.config();

// Colors
const GREEN = "\x1b[32m";
const YELLOW = "\x1b[33m";
const CYAN = "\x1b[36m";
const RED = "\x1b[31m";
const GRAY = "\x1b[90m";
const RESET = "\x1b[0m";

const API_URL = "https://relayer-api.horizenlabs.io/api/v1";
const proof = JSON.parse(fs.readFileSync("./data/proof.json"));
const publicSignals = JSON.parse(fs.readFileSync("./data/public.json"));
const key = JSON.parse(fs.readFileSync("./data/verification_key.json"));

const timestamp = () => {
  return new Date().toISOString().replace("T", " ").replace("Z", "");
};

const log = (msg, obj = null, color = GRAY) => {
  const ts = `[${timestamp()}]`;
  const text = obj ? `${ts} ${msg}: ${JSON.stringify(obj, null, 2)}` : `${ts} ${msg}`;
  console.log(color + text + RESET);
  fs.appendFileSync("logs.txt", text + "\n");
};

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

  try {
    const res = await axios.post(`${API_URL}/submit-proof/${process.env.API_KEY}`, params);
    log("✅ Submitted", res.data, GREEN);

    if (res.data.optimisticVerify !== "success") {
      log("❌ Optimistic verification failed.", null, RED);
      return;
    }

    const jobId = res.data.jobId;
    let attempts = 0;
    const maxRetries = 30; // 30 x 5s = 2.5 minutes

    while (attempts < maxRetries) {
      const job = await axios.get(`${API_URL}/job-status/${process.env.API_KEY}/${jobId}`);
      log(`🔁 Status Check`, job.data, CYAN);

      if (["Finalized", "Verified", "Success"].includes(job.data.status)) {
        log("✅ Proof Completed", job.data, GREEN);
        break;
      }

      attempts++;
      await new Promise(r => setTimeout(r, 5000));
    }

    if (attempts === maxRetries) {
      log("⚠️ Timed out waiting for job to finalize", null, RED);
    }
  } catch (err) {
    log("❌ Error during submission", err.message, RED);
  }
}

main();
EOF

# === INIT NODE PROJECT ===
npm init -y
npm pkg set type=module
npm install axios dotenv

# === TEST FIRST SUBMISSION ===
echo -e "${GREEN}Testing initial submission to zkVerify...${NC}"
node index.js

# === PROMPT: HOW MANY SUBMISSIONS ===
echo -e "${YELLOW}"
echo "Choose how many times to submit the proof:"
echo "1. 100 (50 points)"
echo "2. 250 (100 points)"
echo "3. 500 (200 points)"
echo "4. 1000 (500 points)"
read -rp "Enter your choice (1/2/3/4): " choice
echo -e "${NC}"

case $choice in
  1) loop_count=100 ;;
  2) loop_count=250 ;;
  3) loop_count=500 ;;
  4) loop_count=1000 ;;
  *) echo -e "${RED}Invalid choice. Exiting.${NC}"; exit 1 ;;
esac

# === LOOP PROOF SUBMISSION ===
echo -e "${GREEN}Submitting $loop_count proofs to zkVerify Relayer...${NC}"
cd ~/zkverify-relayer || exit

for ((i = 1; i <= loop_count; i++)); do
  echo -e "${YELLOW}➡️  Proof Submission #$i/$loop_count${NC}"
  node index.js
  echo -e "${YELLOW}😴 cc3 is sleeping for 2 seconds...${NC}"
  sleep 2
done

echo -e "${GREEN}🎉 Finished all $loop_count proof submissions!${NC}"
