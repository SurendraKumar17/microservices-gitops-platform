# ---------- Build stage ----------
FROM node:20-alpine AS build

WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm install --production

COPY . .

# ---------- Runtime stage ----------
FROM node:20-alpine

WORKDIR /app

# install only production deps
COPY --from=build /app /app

ENV NODE_ENV=production
ENV PORT=3000

EXPOSE 3000

USER node 

# use node directly (better for prod than nodemon)
CMD ["node", "app.js"]