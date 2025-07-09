# PHP + Apache 베이스 이미지 사용
FROM php:8.1-apache

# DVWS 코드 복사 (동일 디렉토리에 클론되어 있다고 가정)
COPY . /var/www/html

# 권한 설정
RUN chown -R www-data:www-data /var/www/html

# 포트 노출
EXPOSE 80

# Apache 실행
CMD ["apache2-foreground"]
