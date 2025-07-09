FROM php:8.1-apache

# Apache 설정 명확하게 지정
RUN echo "DocumentRoot /var/www/html" > /etc/apache2/sites-available/000-default.conf

# 웹 앱 파일 복사
COPY . /var/www/html

# 권한 설정
RUN chown -R www-data:www-data /var/www/html

EXPOSE 80

CMD ["apache2-foreground"]
