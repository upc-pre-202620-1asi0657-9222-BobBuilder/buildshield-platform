package pe.buildshield.devkafka;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.kafka.test.EmbeddedKafkaKraftBroker;

/** Levanta el broker KRaft embebido y crea los tópicos con sus particiones. */
@Configuration(proxyBeanMethods = false)
class EmbeddedBrokerConfiguration {

    private static final Logger log = LoggerFactory.getLogger(EmbeddedBrokerConfiguration.class);

    @Bean(destroyMethod = "destroy")
    EmbeddedKafkaKraftBroker embeddedKafkaBroker(DevKafkaProperties properties) {
        EmbeddedKafkaKraftBroker broker = new EmbeddedKafkaKraftBroker(1, properties.partitions(),
                properties.topics().toArray(String[]::new));
        // EmbeddedKafkaKraftBroker ignora kafkaPorts(): el puerto fijo se impone sobrescribiendo los
        // listeners del nodo combinado (broker y controlador). El controlador sigue en un puerto libre.
        broker.brokerProperty("listeners", "EXTERNAL://localhost:" + properties.port() + ",CONTROLLER://localhost:0");
        broker.brokerProperty("auto.create.topics.enable", "true");
        broker.brokerProperty("num.partitions", String.valueOf(properties.partitions()));
        broker.brokerProperty("offsets.topic.replication.factor", "1");
        broker.brokerProperty("transaction.state.log.replication.factor", "1");
        broker.brokerProperty("transaction.state.log.min.isr", "1");
        broker.afterPropertiesSet();
        log.info("Kafka de desarrollo listo en {} con los tópicos {} ({} particiones)",
                broker.getBrokersAsString(), properties.topics(), properties.partitions());
        return broker;
    }
}
