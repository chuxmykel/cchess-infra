# The house bots: cchess's scripted opponent (scripts/opponent.js and its
# engine, copied in by scripts/deploy.sh from a cchess checkout), each
# seeking games as its own account, so a reviewer or tester always finds
# an opponent. Only with COMPOSE_PROFILES=bots in .env.
FROM node:22-alpine
WORKDIR /bots
RUN npm init -y >/dev/null && npm install --no-audit --no-fund chess.js@1.4.0 socket.io-client@4.8.4
COPY opponent.js opponent-ai.js run.sh ./
RUN chmod +x run.sh
USER node
CMD ["./run.sh"]
