FROM maven:3.9-eclipse-temurin-21 AS builder

WORKDIR /var/www/html

COPY pom.xml .
RUN mvn dependency:go-offline -B

COPY src ./src
#RUN mvn clean package -DskipTests
RUN mvn clean verify

FROM eclipse-temurin:21-jre

WORKDIR /var/www/html

COPY --from=builder /var/www/html/target/*.jar app.jar

RUN useradd -u 1001 -m springuser
USER 1001:1001

EXPOSE 8080

CMD ["java", "-jar", "app.jar"]