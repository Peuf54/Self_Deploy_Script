#!/bin/bash

# Variables
GITHUB_USERNAME=$1
PROJECT_NAME=$2
DOMAIN_NAME=$3
IP_ADDRESS=$4
GITHUB_REPO_URL="git@github.com:$GITHUB_USERNAME/$PROJECT_NAME.git"
APP_PATH="/var/www/apps/$PROJECT_NAME"
REPO_PATH="/var/www/repos/$PROJECT_NAME"

# Création de l'utilisateur deploy et configuration des répertoires
sudo adduser deploy --gecos "First Last,RoomNumber,WorkPhone,HomePhone" --disabled-password
echo "deploy:$PROJECT_NAME" | sudo chpasswd
sudo usermod -aG sudo deploy
sudo mkdir -p /var/www/repos /var/www/apps
sudo chown -R deploy:deploy /var/www

# Mise à jour et installation des dépendances
sudo apt update && sudo apt upgrade -y
sudo apt install -y git gh rbenv debian-keyring debian-archive-keyring apt-transport-https

# Configuration GitHub
su deploy -c "cd /var/www/repos && gh auth login"

# Clonage du dépôt GitHub
su deploy -c "cd /var/www/repos && gh repo clone $GITHUB_REPO_URL"

# Installation de RVM et Ruby
su deploy -c "curl -sSL https://get.rvm.io | bash -s"
su deploy -c "source /home/deploy/.rvm/scripts/rvm"
su deploy -c "rvm install 'ruby-3.1.2'"
su deploy -c "rvm use 3.1.2"
su deploy -c "gem update --system && gem install bundler rails"

# Configuration de Gemfile
su deploy -c "cd $REPO_PATH && echo 'group :development do' >> Gemfile"
su deploy -c "cd $REPO_PATH && echo '  gem \"capistrano\", \"~> 3.17\", require: false' >> Gemfile"
su deploy -c "cd $REPO_PATH && echo 'end' >> Gemfile"
su deploy -c "cd $REPO_PATH && echo '' >> Gemfile"
su deploy -c "cd $REPO_PATH && echo 'gem \"ed25519\", \">= 1.2\", \"< 2.0\"' >> Gemfile"
su deploy -c "cd $REPO_PATH && echo 'gem \"bcrypt_pbkdf\", \">= 1.0\", \"< 2.0\"' >> Gemfile"

# Installation des gems
su deploy -c "cd $REPO_PATH && bundle"

# Installation de Capistrano
su deploy -c "cd $REPO_PATH && bundle exec cap install"

# Configuration de Capistrano
su deploy -c "cd $REPO_PATH && truncate -s 0 config/deploy.rb"
su deploy -c "cd $REPO_PATH && cat > config/deploy.rb <<EOF
# config valid for current version and patch releases of Capistrano
lock \"~> 3.17.3\"
set :application, \"$PROJECT_NAME\"
set :repo_url, \"$GITHUB_REPO_URL\"
set :deploy_to, \"$APP_PATH\"
EOF"

su deploy -c "cd $REPO_PATH && truncate -s 0 config/deploy/production.rb"
su deploy -c "cd $REPO_PATH && cat > config/deploy/production.rb <<EOF
server \"$IP_ADDRESS\", user: \"deploy\", roles: %w{app db web}
EOF"

# Configuration du service Puma
sudo bash -c "cat > /etc/systemd/system/puma.service <<EOF
[Unit]
Description=Puma HTTP Server
After=network.target

[Service]
Type=simple
User=deploy
WorkingDirectory=$APP_PATH/current
ExecStart=/home/deploy/.rvm/gems/ruby-3.1.2/wrappers/bundle exec puma -C $APP_PATH/current/config/puma.rb
Restart=always

[Install]
WantedBy=multi-user.target
EOF"

# Déploiement avec Capistrano
su deploy -c "cd $REPO_PATH && bundle exec cap production deploy"

# Installation et configuration de Caddy
sudo bash -c "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg"
sudo bash -c "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list"
sudo apt update
sudo apt install -y caddy

# Configuration des règles iptables
sudo iptables -A INPUT -p tcp --dport 80 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 443 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 3000 -j ACCEPT

# Démarrage des services
sudo systemctl start puma
sudo systemctl start caddy

# Configuration de Caddyfile
sudo truncate -s 0 /etc/caddy/Caddyfile
sudo bash -c "cat > /etc/caddy/Caddyfile <<EOF
$DOMAIN_NAME {
    root * $APP_PATH/current/public
    file_server

    @notStatic {
        not path /assets/*
    }

    reverse_proxy @notStatic localhost:3000
}
EOF"

# Vérification et démarrage de Caddy
cd /etc/caddy
sudo systemctl stop caddy
sudo caddy fmt --overwrite
sudo caddy run

# Configuration de l'environnement de production
su deploy -c "echo 'Rails.application.configure do
  # ...
  config.hosts << \"$DOMAIN_NAME\"
  # ...
end' >> $REPO_PATH/config/environments/production.rb"

# Suppression du contenu original et ajout du nouveau contenu dans le fichier puma.rb
su deploy -c "echo '# Change \"$APP_NAME\" to the actual name of your application
app_name = \"$APP_NAME\"

environment \"production\"

# Specifies the `pidfile` that Puma will use.
pidfile \"/var/www/app/\$app_name/shared/tmp/pids/puma.pid\"

# Specifies the `state_path` for Puma.
state_path \"/var/www/app/\$app_name/shared/tmp/pids/puma.state\"

# Redirect Puma\'s standard output and standard error to log files.
stdout_redirect \"/var/www/app/\$app_name/shared/log/puma.stdout.log\", \"/var/www/app/\$app_name/shared/log/puma.stderr.log\"

# Bind Puma to the port 3000.
bind \"tcp://0.0.0.0:3000\"

# Set the path to your Rails application root.
directory \"/var/www/app/\$app_name/current\"

# Define the number of workers and threads for Puma.
# Adjust these values according to your server\'s resources.
workers 2
threads 4, 8

# Set up the preload_app option for faster worker boot times.
preload_app!

# Allow puma to be restarted by `systemctl restart puma`.
plugin :tmp_restart' > $REPO_PATH/config/puma.rb"

# Génération d'une nouvelle secret_key_base
su deploy -c "cd $APP_PATH/current && rake assets:precompile"
su deploy -c "cd $APP_PATH/current && bin/rails secret > secret_key_base.txt"
SECRET_KEY_BASE=$(su deploy -c "cat $APP_PATH/current/secret_key_base.txt")
su deploy -c "echo 'secret_key_base: $SECRET_KEY_BASE' > $APP_PATH/current/config/credentials/production.key"

# Création des répertoires nécessaires
su deploy -c "mkdir -p $APP_PATH/shared/log/"
su deploy -c "mkdir -p $APP_PATH/shared/tmp/"
su deploy -c "mkdir -p $APP_PATH/shared/tmp/pids/"

# Redémarrage des services
sudo systemctl restart puma
sudo systemctl restart caddy

# Nettoyage
su deploy -c "rm $APP_PATH/current/secret_key_base.txt"

echo "Déploiement terminé. Votre application est maintenant accessible à l'adresse : http://$DOMAIN_NAME"