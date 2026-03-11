FROM node:20.20.1@sha256:bd3086f61c05f8925ed2026bee608a40ad9f8a5d28b6e593342237469ee5b621 AS build

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm install

COPY . .
RUN npm run build

FROM nginx:alpine@sha256:5bad1ddd1ae00bc2cf5d90a6141566cc3f0e05c6deca4106ef04ff5d8a94b280

COPY --from=build /app/dist /usr/share/nginx/html

RUN sed -i 's/application\/javascript.*js;/application\/javascript                js mjs;/' /etc/nginx/mime.types

RUN sed -i 's|index  index.html index.htm;|index  index.html index.htm;\n        try_files $uri $uri/ /index.html;|' /etc/nginx/conf.d/default.conf

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
