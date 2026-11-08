package pe.buildshield.devkafka;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.util.List;

/**
 * Configuración del broker de desarrollo ({@code devkafka.*}).
 *
 * @param port       puerto del listener de clientes (9092 por defecto)
 * @param partitions particiones de cada tópico (3, como en el plan)
 * @param topics     tópicos que se crean al arrancar
 */
@ConfigurationProperties(prefix = "devkafka")
public record DevKafkaProperties(Integer port, Integer partitions, List<String> topics) {

    public DevKafkaProperties {
        port = port == null ? 9092 : port;
        partitions = partitions == null ? 3 : partitions;
        topics = topics == null ? List.of() : List.copyOf(topics);
    }
}
