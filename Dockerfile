FROM node:20.20.1@sha256:f6a6faaedf0e8ec72d6f56f421f2dcb3871da0943b08c342bfed527357ff3e7c AS build

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm install

COPY . .
RUN npm run build

FROM nginx:alpine@sha256:f46cb72c7df02710e693e863a983ac42f6a9579058a59a35f1ae36c9958e4ce0

COPY --from=build /app/dist /usr/share/nginx/html

RUN sed -i 's/application\/javascript.*js;/application\/javascript                js mjs;/' /etc/nginx/mime.types

RUN sed -i 's|index  index.html index.htm;|index  index.html index.htm;\n        try_files $uri $uri/ /index.html;|' /etc/nginx/conf.d/default.conf

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
