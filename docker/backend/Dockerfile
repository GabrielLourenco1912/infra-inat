# syntax=docker/dockerfile:1

FROM maven:3.9-eclipse-temurin-21 AS builder

WORKDIR /app

COPY backend/pom.xml ./pom.xml
RUN mvn --batch-mode --no-transfer-progress dependency:go-offline

COPY backend/src ./src
RUN mvn --batch-mode --no-transfer-progress package -DskipTests

FROM eclipse-temurin:21-jre AS runtime

WORKDIR /app

RUN groupadd --gid 1001 spring \
    && useradd --uid 1001 --gid spring --create-home --shell /usr/sbin/nologin spring \
    && mkdir -p /var/lib/inat/files \
    && chown -R 1001:1001 /var/lib/inat

COPY --from=builder --chown=1001:1001 /app/target/*.jar ./app.jar

USER 1001:1001

EXPOSE 8080

CMD ["java", "-jar", "app.jar"]
