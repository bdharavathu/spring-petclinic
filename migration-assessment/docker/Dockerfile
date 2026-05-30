# syntax=docker/dockerfile:1
# build from the repo root: docker build -f migration-assessment/docker/Dockerfile -t petclinic .

FROM eclipse-temurin:21-jdk AS build
WORKDIR /workspace
COPY .mvn/ .mvn/
COPY mvnw pom.xml ./
RUN chmod +x mvnw
COPY src/ src/
RUN --mount=type=cache,target=/root/.m2 \
    ./mvnw -B -DskipTests clean package && \
    cp target/*.jar /workspace/app.jar

# distroless, nonroot (uid 65532): no shell or package manager
FROM gcr.io/distroless/java21-debian12:nonroot AS runtime
WORKDIR /app
COPY --from=build /workspace/app.jar /app/app.jar
USER nonroot
EXPOSE 8080
ENV JDK_JAVA_OPTIONS="" \
    SPRING_PROFILES_ACTIVE="postgres"
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
