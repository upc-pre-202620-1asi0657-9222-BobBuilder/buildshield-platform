package pe.buildshield.devkafka;

import org.apache.kafka.clients.admin.AdminClient;
import org.apache.kafka.clients.admin.AdminClientConfig;
import org.apache.kafka.clients.admin.TopicDescription;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.kafka.test.EmbeddedKafkaKraftBroker;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import java.io.IOException;
import java.net.ServerSocket;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/** El broker arranca en el puerto configurado (uno libre en la prueba) con los 6 tópicos de 3 particiones. */
@SpringBootTest(properties = "spring.main.keep-alive=false")
class DevKafkaApplicationTest {

    private static final int PORT = freePort();

    @DynamicPropertySource
    static void port(DynamicPropertyRegistry registry) {
        registry.add("devkafka.port", () -> PORT);
    }

    private static final List<String> TOPICS = List.of("buildshield.iam", "buildshield.organization",
            "buildshield.inventory", "buildshield.ordering", "buildshield.discrepancy", "buildshield.subscription");

    @Autowired
    EmbeddedKafkaKraftBroker broker;

    @Test
    void listens_on_the_configured_port() {
        assertThat(broker.getBrokersAsString()).isEqualTo("localhost:" + PORT);
    }

    @Test
    void creates_the_six_topics_with_three_partitions() throws Exception {
        try (AdminClient admin = AdminClient.create(Map.of(
                AdminClientConfig.BOOTSTRAP_SERVERS_CONFIG, broker.getBrokersAsString()))) {
            assertThat(admin.listTopics().names().get()).containsAll(TOPICS);
            Map<String, TopicDescription> descriptions = admin.describeTopics(TOPICS).allTopicNames().get();
            assertThat(descriptions.values()).allSatisfy(topic -> assertThat(topic.partitions()).hasSize(3));
        }
    }

    private static int freePort() {
        try (ServerSocket socket = new ServerSocket(0)) {
            return socket.getLocalPort();
        } catch (IOException ex) {
            throw new IllegalStateException(ex);
        }
    }
}
