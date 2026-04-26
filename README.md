DAC Panel Installation
Just run this command on your fresh Ubuntu/Debian server:

bash <(curl -Ls https://raw.githubusercontent.com/rezajakson/DAC-Panel/main/install.sh)
After installation, access your panel at http://your-server-ip:3000


npm i -g pm2
pm2 start /root/dac-panel/server/index.js --name "dac-panel"
