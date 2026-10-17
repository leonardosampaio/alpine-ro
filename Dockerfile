# Builder do ISO Alpine RO: so precisa do xorriso; nao exige privilegios nem VM.
FROM alpine:3.24
RUN apk add --no-cache xorriso tar
COPY iso-src/ /src/
RUN find /src -type f -exec sed -i 's/\r$//' {} + && chmod 755 /src/build.sh
ENV OUT=/out
VOLUME /out
ENTRYPOINT ["sh", "/src/build.sh"]
