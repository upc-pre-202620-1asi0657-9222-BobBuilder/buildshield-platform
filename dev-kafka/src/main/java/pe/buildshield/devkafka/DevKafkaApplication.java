package pe.buildshield.devkafka;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.ConfigurationPropertiesScan;

/**
 * Broker Kafka de desarrollo: un nodo KRaft embebido en {@code localhost:9092} con los tópicos de
 * BuildShield ya creados. Reemplaza a Docker en las máquinas que no lo tienen. Los mensajes viven
 * mientras el proceso está arriba: al reiniciarlo, los tópicos se crean vacíos.
 */
@SpringBootApplication
@ConfigurationPropertiesScan
public class DevKafkaApplication {

    public static void main(String[] args) {
        SpringApplication.run(DevKafkaApplication.class, args);
    }
}
