FROM php:8.1-apache

# DVWS 코드 복사
COPY . /var/www/html

# Apache 설정 변경: DocumentRoot를 /var/www/html/html 로 수정
RUN sed -i 's|DocumentRoot /var/www/html|DocumentRoot /var/www/html/html|' /etc/apache2/sites-available/000-default.conf

# 권한 설정
RUN chown -R www-data:www-data /var/www/html

EXPOSE 80

CMD ["apache2-foreground"]
