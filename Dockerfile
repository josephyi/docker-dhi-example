# syntax=docker/dockerfile:1

FROM dhi.io/eclipse-temurin:25-jdk-debian13-dev AS builder

# jlink requires binutils to be installed
RUN apt update && apt-get install -y -qq binutils

WORKDIR /workspace
COPY --link ./gradle ./gradle
COPY --link gradlew *.gradle.* *.gradle ./
RUN --mount=type=cache,target=/root/.gradle \ 
    ./gradlew --no-daemon -q dependencies

COPY ./src ./src
RUN --mount=type=cache,target=/root/.gradle \
    ./gradlew bootJar --no-daemon \
    && java -Djarmode=tools \
            -jar ./build/libs/application.jar \
            extract --layers --destination extracted \
    && JAVA_RUNTIME_MODULES="$(jdeps \
       --ignore-missing-deps \
       -q \
       -R \
       --multi-release 25 \
       --print-module-deps \
       --class-path="./extracted/dependencies/lib/*" \
       --module-path="./extracted/dependencies/lib/*" \
       ./build/libs/application.jar)" \
    && jlink \
       --no-header-files \
       --no-man-pages \
       --strip-debug \
       --compress=zip-6 \
       --add-modules "${JAVA_RUNTIME_MODULES}" \
       --output javaruntime

FROM dhi.io/debian-base:trixie AS aot-cache-training-runner
ENV JAVA_HOME=/opt/java/openjdk
ENV PATH="${JAVA_HOME}/bin:${PATH}"
WORKDIR /workspace
COPY --link --from=builder /workspace/javaruntime ${JAVA_HOME}
COPY --link --from=builder /workspace/extracted/dependencies ./
COPY --link --from=builder /workspace/extracted/spring-boot-loader ./
COPY --link --from=builder /workspace/extracted/snapshot-dependencies ./
COPY --link --from=builder /workspace/extracted/application ./
RUN java -XX:AOTCacheOutput=app.aot -Dspring.context.exit=onRefresh -jar application.jar

FROM gcr.io/distroless/java-base-debian13 AS runtime
ENV JAVA_HOME=/opt/java/openjdk
ENV PATH="${JAVA_HOME}/bin:${PATH}"
WORKDIR /app
COPY --link --from=builder /workspace/javaruntime ${JAVA_HOME}
COPY --link --from=builder /workspace/extracted/dependencies ./
COPY --link --from=builder /workspace/extracted/spring-boot-loader ./
COPY --link --from=builder /workspace/extracted/snapshot-dependencies ./
COPY --link --from=builder /workspace/extracted/application ./
COPY --link --from=aot-cache-training-runner /workspace/app.aot .
ENTRYPOINT ["java", "-XX:AOTCache=app.aot", "-Xlog:aot,cds", "-jar", "application.jar"]
