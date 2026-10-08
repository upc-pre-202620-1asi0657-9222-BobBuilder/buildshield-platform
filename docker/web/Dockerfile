# Imagen de la web (buildshield-web) para docker-compose. Se construye con el contexto ../buildshield-web
# y toma nginx.conf del contexto adicional "platform" (esta carpeta), sin tocar el repositorio de la web.
FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npx ng build --configuration production

FROM nginx:1.27-alpine
COPY --from=platform nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist/buildshield-web/browser /usr/share/nginx/html
EXPOSE 80
