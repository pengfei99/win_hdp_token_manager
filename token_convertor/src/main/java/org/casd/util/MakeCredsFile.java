import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.fs.Path;
import org.apache.hadoop.io.Text;
import org.apache.hadoop.security.Credentials;
import org.apache.hadoop.security.token.Token;

/**
 * Convertit des delegation tokens (obtenus via WebHDFS / API REST du ResourceManager)
 * en fichier de credentials Hadoop utilisable via HADOOP_TOKEN_FILE_LOCATION.
 *
 * Usage : MakeCredsFile <fichierSortie> (<kind> <urlString> <service>)...
 *
 * Compilation :
 *   $cp = (hdfs classpath | Out-String).Trim()
 *   javac --release 11 -cp "$cp" MakeCredsFile.java
 */
public class MakeCredsFile {
    public static void main(String[] args) throws Exception {
        if (args.length < 4 || (args.length - 1) % 3 != 0) {
            System.err.println("Usage: MakeCredsFile <outFile> (<kind> <urlString> <service>)...");
            System.err.println("Arguments recus: " + args.length + " (attendu: 1 + multiple de 3)");
            System.err.println("Cause frequente: variable PowerShell vide supprimee des arguments.");
            System.exit(2);
        }
        String outFile = args[0];
        Credentials creds = new Credentials();
        for (int i = 1; i < args.length; i += 3) {
            String kind = args[i], url = args[i + 1], service = args[i + 2];
            if (url.length() < 40) {
                System.err.println("ERREUR: token " + kind + " vide ou invalide (longueur " + url.length() + ")");
                System.exit(2);
            }
            Token<?> t = new Token<>();
            try {
                t.decodeFromUrlString(url);
            } catch (Exception e) {
                System.err.println("ERREUR: decodage du token " + kind + " impossible: " + e);
                System.exit(2);
            }
            t.setKind(new Text(kind));
            t.setService(new Text(service));
            creds.addToken(new Text(kind + "@" + service), t);
            System.out.println("Added kind=" + kind + " service=" + service);
        }
        creds.writeTokenStorageFile(new Path("file:///" + outFile.replace('\\', '/')), new Configuration());
        System.out.println("Written: " + outFile);
    }
}