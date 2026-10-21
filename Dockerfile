FROM nginx:1.27-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html test.html style.css change-password.html Comfortaa-VariableFont_wght-BRqhndbG.ttf /usr/share/nginx/html/

EXPOSE 80 3000
