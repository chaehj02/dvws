# PHP + Apache 베이스 이미지 사용
FROM php:8.1-apache

# DVWS 코드 복사
COPY . /var/www/html

# html 하위 링크가 필요한 문제 해결
RUN mkdir -p /var/www/html/html && \
    ln -s /var/www/html/* /var/www/html/html

# 권한 설정
RUN chown -R www-data:www-data /var/www/html

# 포트 노출
EXPOSE 80

# Apache 실행
CMD ["apache2-foreground"]
