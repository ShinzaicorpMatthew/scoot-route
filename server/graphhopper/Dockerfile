FROM eclipse-temurin:21-jre

# Vérifiez la dernière version sur https://github.com/graphhopper/graphhopper/releases
ARG GH_VERSION=11.0

WORKDIR /gh
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL -o graphhopper-web.jar \
       "https://repo1.maven.org/maven2/com/graphhopper/graphhopper-web/${GH_VERSION}/graphhopper-web-${GH_VERSION}.jar"

COPY config.yml /gh/config.yml
COPY custom_models /gh/custom_models

EXPOSE 8989
# Lyon métropole : 2 Go de heap suffisent largement (import + routage)
ENV JAVA_OPTS="-Xms1g -Xmx2g"
CMD ["sh", "-c", "java $JAVA_OPTS -jar graphhopper-web.jar server /gh/config.yml"]
