.PHONY: help up down restart-n1 restart-n2 logs-n1 logs-n2 status qr1 qr2 backup cw-prepare pull

help:
	@echo "make up            - levanta toda la plataforma"
	@echo "make cw-prepare    - prepara la base de Chatwoot (solo la 1a vez)"
	@echo "make qr1 / qr2     - da de alta / reconecta un numero y saca el QR"
	@echo "make status        - estado de los 2 numeros + IP de cada proxy"
	@echo "make restart-n1    - reinicia SOLO el numero 1 (el 2 no se entera)"
	@echo "make logs-n1       - logs en vivo del numero 1"
	@echo "make backup        - copia de bases de datos y sesiones"

up:
	docker compose up -d

down:
	docker compose down

pull:
	docker compose pull

cw-prepare:
	docker compose run --rm chatwoot bundle exec rails db:chatwoot_prepare

qr1:
	./scripts/provision.sh n1
qr2:
	./scripts/provision.sh n2

restart-n1:
	docker compose restart evolution-n1
restart-n2:
	docker compose restart evolution-n2

logs-n1:
	docker compose logs -f --tail=200 evolution-n1
logs-n2:
	docker compose logs -f --tail=200 evolution-n2

status:
	./scripts/status.sh

backup:
	./scripts/backup.sh
