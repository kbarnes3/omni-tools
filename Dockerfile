FROM node:20.20.1@sha256:e391c5561646193be929e3fe55d27234f40a01d867d72b30ae1341b673a3bf4b AS build

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm install

COPY . .
RUN npm run build

FROM nginx:alpine@sha256:d436955245d0951d806af5e0ce0df7d111c9d4c6329f00f7ad69282a3be74f27

COPY --from=build /app/dist /usr/share/nginx/html

RUN sed -i 's/application\/javascript.*js;/application\/javascript                js mjs;/' /etc/nginx/mime.types

RUN sed -i 's|index  index.html index.htm;|index  index.html index.htm;\n        try_files $uri $uri/ /index.html;|' /etc/nginx/conf.d/default.conf

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
