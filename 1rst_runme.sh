pwd
git clone https://github.com/yerikalarcon/fb-install.git
cd ~/fb-install
sudo mkdir -p /etc/ssl/certificados/
sudo mv *.pem /etc/ssl/certificados/
sudo chmod 600 /etc/ssl/certificados/privkey.pem
sudo chmod 644 /etc/ssl/certificados/fullchain.pem

chmod +x *.sh

# Ahora si ejecuta la instalacion: 
# sudo bash instala-fb.sh fb.urmah.ai --cert /etc/ssl/certificados/fullchain.pem --key /etc/ssl/certificados/privkey.pem
