package org.casd.util;

import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.fs.Path;
import org.apache.hadoop.io.Text;
import org.apache.hadoop.security.Credentials;
import org.apache.hadoop.security.SecurityUtil;
import org.apache.hadoop.security.token.Token;

import java.io.File;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.URI;
import java.net.URISyntaxException;
import java.util.Objects;
import java.util.logging.Level;
import java.util.logging.Logger;

/**
 * Encapsulates Hadoop delegation token strings into a binary credentials file.
 */
public final class MakeCredsFile {

    private static final Logger LOGGER = Logger.getLogger(MakeCredsFile.class.getName());
    private static final int MIN_TOKEN_LENGTH = 40;
    private static final int PARAMS_PER_TOKEN = 3;

    private MakeCredsFile() {
        // Utility class
    }

    public static void main(String[] args) {
        try {
            run(args);
        } catch (IllegalArgumentException e) {
            LOGGER.log(Level.SEVERE, "Invalid arguments: {0}", e.getMessage());
            printUsage();
            System.exit(2);
        } catch (IOException e) {
            LOGGER.log(Level.SEVERE, "I/O or Serialization failure: {0}", e.getMessage());
            System.exit(1);
        }
    }

    /**
     * Validates the token kind and returns it as a Text.
     * Only HDFS_DELEGATION_TOKEN and RM_DELEGATION_TOKEN are supported.
     *
     * @param kind the token kind string
     * @return Text representation of the kind
     * @throws IllegalArgumentException if the kind is not supported
     */
    public static Text buildTokenKind(String kind) {
        if (kind == null || kind.isBlank()) {
            throw new IllegalArgumentException("Token kind cannot be null or empty");
        }

        switch (kind.trim()) {
            case "HDFS_DELEGATION_TOKEN":
            case "RM_DELEGATION_TOKEN":
                return new Text(kind.trim());
            default:
                throw new IllegalArgumentException(
                        "Unsupported token kind: '" + kind + "'. " +
                                "Supported values are: HDFS_DELEGATION_TOKEN, RM_DELEGATION_TOKEN"
                );
        }
    }

    /**
     * Validates the token service and returns it as a Text.
     * The accepted form are: <fqdn>:<port> or <ip>:<port>
     *
     * @param service the token service string
     * @return Text representation of the service
     * @throws IllegalArgumentException if the kind is not supported
     */
    public static Text buildTokenService(String service) {
        if (service == null || service.isBlank()) {
            throw new IllegalArgumentException("Token service cannot be null or empty");
        }
        String trimmedService = service.trim();
        try {
            // Prepend a dummy scheme so URI can parse authority components accurately
            URI uri = new URI("dummy://" + trimmedService);

            String host = uri.getHost();
            int port = uri.getPort();

            if (host == null) {
                throw new IllegalArgumentException("Host cannot be null");
            }

            if (port < 1 || port > 65_535) {
                throw new IllegalArgumentException("Port must be between 1 and 65535, given: " + port);
            }

            return SecurityUtil.buildTokenService(new InetSocketAddress(host, port));


        } catch (URISyntaxException e) {
            throw new IllegalArgumentException("Malformed service address format: " + trimmedService, e);
        }

    }

    /**
     * Main execution logic separated from System.exit for testability.
     */
    public static void run(String[] args) throws IOException {
        Objects.requireNonNull(args, "Arguments array cannot be null");

        if (args.length < (1 + PARAMS_PER_TOKEN) || (args.length - 1) % PARAMS_PER_TOKEN != 0) {
            throw new IllegalArgumentException(
                    String.format("Received %d arguments (Expected: 1 output file + multiples of 3).", args.length)
            );
        }

        String outputPath = args[0];
        Credentials credentials = new Credentials();

        for (int i = 1; i < args.length; i += PARAMS_PER_TOKEN) {
            String kind = args[i];
            String encodedToken = args[i + 1];
            String service = args[i + 2];

            processToken(credentials, kind, encodedToken, service);
        }

        writeCredentialsToFile(credentials, outputPath);
    }

    private static void processToken(Credentials credentials, String kind, String encodedToken, String service) throws IOException {
        if (encodedToken == null || encodedToken.length() < MIN_TOKEN_LENGTH) {
            throw new IllegalArgumentException(
                    String.format("Token string for kind '%s' is empty or invalid (length: %d)",
                            kind, encodedToken == null ? 0 : encodedToken.length())
            );
        }

        Token<?> token = new Token<>();
        try {
            token.decodeFromUrlString(encodedToken);
        } catch (IOException e) {
            throw new IOException(String.format("Failed to decode token for kind '%s'", kind), e);
        }
        // use constructor to handle bad values of kind and service string.
        Text tokenKind = buildTokenKind(kind);
        Text tokenService = buildTokenService(service);
        token.setKind(tokenKind);
        token.setService(tokenService);

        // Use token's internal service alias for standard Hadoop resolution
        Text alias = token.getService().getLength() > 0 ? token.getService() : new Text(kind + "@" + service);
        credentials.addToken(alias, token);

        LOGGER.log(Level.INFO, "Added token [kind={0}, service={1}]", new Object[]{kind, service});
    }

    private static void writeCredentialsToFile(Credentials credentials, String outputPath) throws IOException {
        File file = new File(outputPath).getAbsoluteFile();
        Path hadoopPath = new Path(file.toURI());

        credentials.writeTokenStorageFile(hadoopPath, new Configuration());
        LOGGER.log(Level.INFO, "Successfully generated credentials file: {0}", hadoopPath);
    }

    private static void printUsage() {
        System.err.println("Usage: java MakeCredsFile <outFile> (<kind> <encodedTokenString> <service>)...");
        System.err.println("Note: In PowerShell, ensure empty variables do not get dropped from command arguments.");
    }
}