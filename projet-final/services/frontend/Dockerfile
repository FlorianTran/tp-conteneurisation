# Frontend statique servi par nginx-unprivileged (UID 101, port 8080).
# Compatible PSS restricted comme au TP-5.
FROM nginxinc/nginx-unprivileged:alpine
COPY nginx.conf /etc/nginx/nginx.conf
COPY html/ /usr/share/nginx/html/
EXPOSE 8080
